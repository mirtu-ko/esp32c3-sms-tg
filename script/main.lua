--[[
短信转发器主程序（ESP32C3 + Air780E + LuatOS）
数据流：uartTask 收 AT/URC 解析 PDU -> AT_CMT 事件 -> 本文件攒长短信 -> notify 入队推送
网页面板：webcfg 起 HTTP 服务，联网后浏览器访问 http://<设备IP>/cfg 改配置
固件要求：ESP32C3 v1004 及以上（低版本会有 WiFi 拒连 12298、HTTP "NOT SUPPORT TLS" 等问题）
]]

-- LuaTools需要PROJECT和VERSION这两个信息
PROJECT = "esp32c3-sms-tg"
VERSION = "1.1.0"

--调试日志开关：true=额外输出串口原始报文、AT 收发细节，排查问题才打开；日常看日志保持 false
LOG_DEBUG = false

log.info("main", PROJECT, VERSION)
--把固件版本写进应用日志，免得还要靠启动日志里的 bsp 行去确认刷对版本没有
local ok, ver = pcall(rtos.version)
log.info("main", "firmware", ok and ver or "unknown")

-- 引入必要的库文件(lua编写), 内部库不需要require
sys = require("sys")
require("sysplus")

if wdt then
    --添加硬狗防止程序卡死，在支持的设备上启用这个功能
    wdt.init(9000)--初始化watchdog设置为9s
    sys.timerLoopStart(wdt.feed, 3000)--3s喂一次狗
end

--运营商给的dns经常抽风，手动指定（腾讯/阿里）
socket.setDNS(nil, 1, "119.29.29.29")
socket.setDNS(nil, 2, "223.5.5.5")

--定时 GC（全量 GC 会阻塞其它 task，属于历史做法；真遇内存问题应先查泄漏点）
sys.timerLoopStart(function()
    collectgarbage("collect")
end, 1000)

--顺序不能改：config 要先建好全局，notify 和 webcfg 在运行期都会用到它俩的全局名
led = require("led")--状态灯
config = require("config")--运行期配置（存在 flash 的 KV 库里，网页面板可改）
config.init()
air780 = require("uartTask")--Air780E 的 AT 串口
notify = require("notify")--推送 + 最近短信缓冲

--内存基准：V1004 的 Lua 堆只有 96KB（V1007 是 112KB），这两行是判断余量够不够的唯一依据
local function memlog(tag)
    local okl, tot, used = pcall(rtos.meminfo, "lua")
    local oks, stot, sused = pcall(rtos.meminfo, "sys")
    if okl and type(tot) == "number" then
        log.info("main", tag,
            "lua " .. math.floor(used / 1024) .. "/" .. math.floor(tot / 1024) .. "KB",
            oks and ("sys " .. math.floor(sused / 1024) .. "/" .. math.floor(stot / 1024) .. "KB") or "")
    end
end
memlog("mem before webcfg")

--加载面板前先全量 GC：把前面 6 个模块编译产生的垃圾清掉，给面板腾连续内存（V1004 堆紧）
collectgarbage("collect")

--面板用 pcall 加载：它加载时 OOM 过一次，后果是整个 Lua VM 退出、15s 后重启的死循环，
--连短信转发都跑不起来。所以降级处理：加载失败就当没有面板，其余功能照跑。
local ok_web, web = pcall(require, "webcfg")
if ok_web then
    webcfg = web
else
    webcfg = nil
    log.error("main", "webcfg load failed, panel disabled:", tostring(web))
end
memlog("mem after webcfg")

--清空数组式 table 的元素（保留 table 本身，方便复用引用）
local function clear_table(t)
    for i = 1, #t do
        t[i] = nil
    end
end

--PDU 时间串 "26/10/06,19:14:31+32" -> "2026-10-06 19:14:31 +08"
--年份只有两位，硬编码补 "20"；格式不对时返回空串，不阻断后续流程
local function fix_time(time)
    if not time or #time < 19 then
        log.warn("main", "bad sms time", tostring(time))
        return ""
    end
    return string.format("20%s-%s-%s %s:%s:%s %s", time:sub(1,2), time:sub(4,5), time:sub(7,8),
    time:sub(10,11), time:sub(13,14), time:sub(16,17), time:sub(18,20))
end

--长短信分片缓冲：long_sms_buffer[发件人][sms_id] = {{id=片号, data=分片内容, time=时间}, ...}
--用「号码 + sms_id」两级键：同一号码可能同时来几条长短信，只有 sms_id 相同才算同一条
local long_sms_buffer = {}

--把攒齐的分片校验、排序、拼接后交给 notify（参数：phone / time / total / sms 分片数组）
local function concat_and_send_long_sms(phone, time, total, sms)
    --片号必须唯一且落在 1..total，否则拼出来的内容是错的
    local seen = {}
    for _, v in ipairs(sms) do
        if v.id == nil or v.id < 1 or v.id > total or seen[v.id] then
            log.error("sms", "bad fragments, drop", phone, total, v.id)
            clear_table(sms)
            return
        end
        seen[v.id] = true
    end

    --运营商上报顺序可能乱，必须按片号排序后再拼
    local full_content = ""
    table.sort(sms, function(a,b) return a.id < b.id end)

    for _, v in ipairs(sms) do
        if LOG_DEBUG then
            --v.data 是 UTF-16BE 二进制，直接打进日志是乱码，只记长度
            log.debug("sms", "fragment", v.id, #v.data, v.time)
        end
        --分片内容是 UTF-16BE 二进制，按字节首尾相接就能还原成完整的 UCS2 流
        full_content = full_content .. v.data
    end

    notify.add(phone, full_content, time)
    clear_table(sms)
end

--分片超时兜底：30s 没凑齐就把已收到的拼掉（宁可少字也别让缓存一直占着）
local function clean_sms_buffer(phone, time, total, sms_id)
    if not long_sms_buffer[phone] then
        return
    end

    if not long_sms_buffer[phone][sms_id] then
        return
    end

    log.warn("sms", "long sms timeout, got", #long_sms_buffer[phone][sms_id], "/", total,
        "from", phone, time, sms_id)
    if #long_sms_buffer[phone][sms_id] > 0 then
        concat_and_send_long_sms(phone, time, total, long_sms_buffer[phone][sms_id])
        long_sms_buffer[phone][sms_id] = nil
        if next(long_sms_buffer[phone]) == nil then
            long_sms_buffer[phone] = nil
        end
    end
end

sys.taskInit(function()
    led.status = 1--5 秒一闪：模组还没响应
    log.info("main","sync at")
    --同步AT命令看通不通（模组没反应时会每 200ms 重发一次，直到收到回显）
    air780.loopAT("AT","AT_AT")

    --重启模组，清掉上一次运行留下的状态
    air780.write("AT+RESET")
    --重启后再同步一次，确认模组起来了
    air780.loopAT("AT","AT_AT")
    --打开命令回显（uartTask 靠回显来确认命令已被模组接受）
    air780.loopAT("ATE1","AT_ATE1")

    --关闭自动升级，避免模组自己联网升级把配置冲掉
    air780.loopAT("AT+UPGRADE=\"AUTO\",0","AT_UPGRADE")

    led.status = 3--1 秒一闪：还没联网
    log.info("main","check sim card")
    --无卡不再直接退出，两种原因都要能自愈：
    --  1) 紧跟 AT+RESET，模组常回 "+CME ERROR: 14 SIM busy"，几秒后就好
    --  2) 真没插卡 —— 插上后能被识别就自动继续，不用重启设备
    local sim_tries = 0
    while true do
        --loopAT 返回的是模组答复的参数（true=READY），不是"命令是否发出"
        if air780.loopAT("AT+CPIN?","AT_CPIN",2000) then break end
        sim_tries = sim_tries + 1
        led.status = 2--常亮：无卡
        --前 3 次每 3s 试（覆盖复位后 "SIM busy" 的瞬时窗口），之后放慢到 30s 一次：
        --没插卡时每 3s 问一次会让 "CPIN failed" 刷屏，而且模组应答本身也会变慢。
        --放慢后插上卡最多 30s 也能自动接上。
        if sim_tries == 1 then
            log.warn("main","sim not ready, retry every 3s")
        elseif sim_tries == 4 then
            log.warn("main","still no sim card, now check every 30s (insert sim to continue)")
        end
        sys.wait(sim_tries <= 3 and 3000 or 30000)
    end
    led.status = 3
    log.info("main","sim ready")

    log.info("main","configrate")
    --短信走 PDU 模式（TEXT 模式对中文支持不好）
    air780.loopAT("AT+CMGF=0","AT_CMGF")
    --字符集设为 UCS2，保证中文能正常收发
    air780.loopAT("AT+CSCS=\"UCS2\"","AT_CSCS")
    --新短信立即用 +CMT 上报，不存进模组（2,2）
    air780.loopAT("AT+CNMI=2,2,0,0,0","AT_CNMI")

    --等基站附着，没附着就每秒重试
    log.info("main","wait for network attach")
    local attached, warned = false, false
    while true do
        attached = air780.loopAT("AT+CGATT?","AT_CGATT",1000)
        if attached then break end
        --只提示一遍，避免每秒刷一行把日志冲掉
        if not warned then
            log.warn("main","not attached yet, retry every 1s")
            warned = true
        end
    end
    led.status = 4--0.2 秒一闪：正常待机
    log.info("main","attached, wait for sms")

    --收短信主循环：等 uartTask 发布的 AT_CMT 事件
    --参数依次是 phone / data(UTF-16BE) / time / long / total / id / sms_id
    while true do
        collectgarbage("collect")
        local _, phone, data, time, long, total, id, sms_id = sys.waitUntil("AT_CMT")
        if not phone or not data or not time then
            log.error("sms", "invalid CMT data", phone, data, time)
            goto continue
        end
        --非标准 UDH 的长短信拿不到 sms_id/total/id，而 nil 当 table 键赋值会直接抛错挂掉 task
        if long and (not sms_id or not total or not id) then
            log.error("sms", "bad udh, drop", phone, sms_id, total, id)
            goto continue
        end
        time = fix_time(time)

        if long then--长短信：先攒齐再拼
            log.info("sms","long sms", phone, sms_id, id .. "/" .. total, time)
            if not long_sms_buffer[phone] then
                long_sms_buffer[phone] = {}
            end
            --第一次见到这个分组号时，挂一个超时定时器兜底
            if not long_sms_buffer[phone][sms_id] then
                long_sms_buffer[phone][sms_id] = {}
                sys.timerStart(clean_sms_buffer, 30*1000, phone, time, total, sms_id)
            end

            --按片号去重，运营商可能重发同一片
            local dup = false
            for _, v in ipairs(long_sms_buffer[phone][sms_id]) do
                if v.id == id then
                    dup = true
                    break
                end
            end
            if dup then
                log.warn("sms", "duplicate fragment, drop", phone, sms_id, id)
            else
                table.insert(long_sms_buffer[phone][sms_id], {id = id, data = data, time = time})
            end

            --凑齐 total 片就拼接送走，并把这条分组和空了的号码缓存一起清掉
            if long_sms_buffer[phone][sms_id] and #long_sms_buffer[phone][sms_id] == total then
                concat_and_send_long_sms(phone, time, total, long_sms_buffer[phone][sms_id])
                long_sms_buffer[phone][sms_id] = nil
                if next(long_sms_buffer[phone]) == nil then
                    long_sms_buffer[phone] = nil
                end
            end
        else
            --普通短信：uartTask 已经打过一条 "sms recv"，这里直接交出去转码、入队、推送
            notify.add(phone, data, time)
        end
        ::continue::
    end
end)



-- 用户代码已结束---------------------------------------------
-- 结尾总是这一句
sys.run()
-- sys.run()之后后面不要加任何语句!!!!!
