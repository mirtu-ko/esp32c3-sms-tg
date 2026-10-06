--[[
短信入队 + WiFi 连接 + 推送（本项目只保留 Telegram 通道）

流程：notify.add(phone, data[, time]) 由 main.lua 调用，data 是 UTF-16BE 二进制，先转 UTF-8；
  顺便处理"短信指令"（正文开头匹配，口令取 config.tag）：
    C<tag>REBOOT            10 秒后重启设备
    C<tag>SEND手机号 内容   让 Air780E 主动发一条短信
  然后塞进 buff 队列、publish SMS_ADD，推送 task 连上 WiFi 后依次推给 Telegram；
  另外联网后会延时推一条"开机通知"，陷入重启循环时会反复来，一眼能看出。

配置来源：全局 config（config.lua，由 main.lua 先 require）。token / chat / 口令 / 重试参数
  都是"用时现读"，面板改完立刻生效；WiFi 列表只在启动时读一次，所以改 WiFi 必须重启。

安全提醒：WiFi 密码和 token 明文存在 flash 里；指令只用 tag 当口令，知道号码的人就能远程
  重启设备、往任意号码发短信；面板不做鉴权，别把 80 端口映射到公网。
]]

local notify = {}

--开机通知：设备启动联网后延时推一条 Telegram 消息（一般开机十几秒收到）；改成 0 关闭。
--不放进面板的原因：这个值只在重启那一次用得上，而配置存内存里、重启就回默认值
local BOOT_NOTICE_DELAY = 10
--等联网的最长秒数：超时就放弃这条通知，不影响其它功能
local BOOT_NOTICE_NET_TIMEOUT = 90

--读配置项：config 由 main.lua 创建；没有就用兜底值，保证设备还能跑
local function cget(key, default)
    local c = _G.config
    if c and c.get then
        local v = c.get(key)
        if v ~= nil then return v end
    end
    return default
end

--当前存储后端名（开机通知里报一下）：只有 memory 时配置重启就丢
local function backend_name()
    local c = _G.config
    if c and c.backend then
        local ok, b = pcall(c.backend)
        if ok and b then return tostring(b) end
    end
    return "?"
end

--待推送队列：{{发件人, 内容}, ...}，最多 50 条，满了丢最旧的（防断网时内存被撑爆）
local buff = {}

--最近收到的短信（环形，给面板看的），每条 {phone, text, time}
--V1004 的 Lua 堆只有 96KB，这里限 12 条 / 每条 240 字节，避免面板历史把内存吃掉
local HISTORY_MAX = 12
local history = {}

--当前连上的 WiFi 名 + 最后一次推送结果，都是给面板显示用的
local wifi_name = ""
notify.lastPush = nil

function notify.queueLen()
    return #buff
end

function notify.wifiName()
    return wifi_name
end

function notify.history()
    return history
end

local function push_history(phone, text, time)
    --内容截断：面板只看个大概，没必要为它保留整条长短信（sub 按字节截，够用）
    history[#history + 1] = {phone = phone, text = text:sub(1, 240), time = time or ""}
    while #history > HISTORY_MAX do
        table.remove(history, 1)
    end
end

--把一条文本推到 Telegram；返回 成功与否, 最后一次状态码，同时把结果写进
--notify.lastPush 供面板显示"上次推送"
local function push_text(text)
    local token = cget("token", "")
    local chat = cget("chat", "")
    if token == "" or chat == "" then
        log.error("notify", "telegram token/chat not configured")
        notify.lastPush = {ok = false, code = "未配置 token/chat"}
        return false, "no token"
    end

    --Telegram Bot API：GET /bot<token>/sendMessage?chat_id=xx&text=xx
    --正文必须 urlEncode；内容很长时 URL 会变长，要留意长度上限
    local url = "https://api.telegram.org/bot" .. token ..
        "/sendMessage?chat_id=" .. chat ..
        "&text=" .. string.urlEncode(text)

    --重试次数/间隔也能在面板里改（网络差时这里最长会占住推送 task：pushMax × pushGap）
    local n = math.floor(tonumber(cget("pushMax", 10)) or 10)
    local gap = math.floor(tonumber(cget("pushGap", 5000)) or 5000)
    local code, body
    for i = 1, n do
        code, _, body = http.request("GET", url).wait()
        if code == 200 then
            notify.lastPush = {ok = true, code = 200}
            return true, code
        end
        --失败时打响应体（截断），成功时不必刷一屏 JSON
        log.warn("notify", "push failed", i .. "/" .. n, code, body and body:sub(1, 150) or "")
        sys.wait(gap)
    end
    notify.lastPush = {ok = false, code = tostring(code)}
    return false, code
end

--面板上的"测试推送"按钮：起个 task 发一条固定文本，不阻塞 http 回调
function notify.test()
    sys.taskInit(function()
        local ok, code = push_text("[测试] 短信转发器配置面板")
        log.info("notify", "test push", ok, code)
    end)
    return true
end

--来新消息了（参数：phone 发件人 / data 内容 UTF-16BE 二进制 / time 短信时间，可选）
function notify.add(phone, data, time)
    local decoded = pdu.ucs2_utf8(data)--转码：UTF-16BE -> UTF-8
    if not decoded then
        log.error("notify", "ucs2_utf8 decode failed", phone)
        decoded = tostring(data)
    end
    data = decoded
    log.info("notify", "got sms", phone, data)
    push_history(phone, data, time)

    --口令是运行时读的，面板改了立刻生效
    local cmdTag = tostring(cget("tag", "ziw"))
    --匹配上了指令（指令要写在短信正文最开头）
    if data:find("C" .. cmdTag) == 1 then
        log.info("cmd", "matched cmd", phone)
        if data:find("C" .. cmdTag .. "REBOOT") == 1 then
            --延迟 10 秒重启，留出时间把下面这条"命令已执行"的通知发出去
            sys.timerStart(rtos.reboot, 10000)
            data = "reboot command done"
        elseif data:find("C" .. cmdTag .. "SEND") == 1 then
            local _, _, phone, text = data:find("C" .. cmdTag .. "SEND(%d+) +(.+)")
            if phone and text then
                log.info("cmd", "cmd send sms", phone, text)
                local d, len = pdu.encodePDU(phone, text)
                if d and len then
                    --注意 write() 会自动补 \r\n，这里不要再手写，否则会多出一个空行
                    air780.write("AT+CMGS=" .. len)
                    --等模组回 "> " 提示符，然后按「PDU 正文 + Ctrl+Z(0x1A)」的顺序发出去
                    local r = sys.waitUntil("AT_SEND_SMS", 5000)
                    if r then
                        air780.write(d, true)
                        sys.wait(500)
                        air780.write(string.char(0x1A), true)
                        data = "send sms at command done"
                    else
                        log.error("cmd", "wait AT_SEND_SMS timeout", phone)
                        data = "send sms at command error!"
                    end
                else
                    log.error("cmd", "encodePDU failed", phone, text)
                end
            else
                log.warn("cmd", "bad SEND format", data)
            end
        end
    end
    --防止网络异常时队列无限增长导致内存不足
    if #buff >= 50 then
        log.warn("notify", "queue full, drop oldest sms", buff[1][1])
        table.remove(buff, 1)
    end
    table.insert(buff, {phone, data})
    sys.publish("SMS_ADD")--推个事件，叫醒下面的推送 task
end


sys.taskInit(function()
    sys.wait(1000)--等系统里其它 task 初始化完
    wlan.init()--初始化wifi
    --依次尝试配置里的每个 WiFi，连上就跳出循环；列表来自 config，面板改完下次连接就生效
    local wifis = cget("wifi", {})
    if #wifis == 0 then
        log.error("wlan", "no wifi configured, check config.lua / panel")
        rtos.reboot()
    end
    for i, wifi in ipairs(wifis) do
        log.info("wlan", "trying wifi #" .. i .. " " .. wifi.name)
        local conn = wlan.connect(wifi.name, wifi.password)
        --连接返回值要看：驱动当场拒绝（如 12298 ESP_ERR_WIFI_SSID）时，
        --下面那 30s 等待纯属白等，看这行就能立刻区分"没连上"和"根本没发出去"
        log.info("wlan", "connect ret", tostring(conn))
        log.info("wlan", "wait for IP_READY")
        sys.waitUntil("IP_READY", 30 * 1000)--最多等 30 秒拿到 IP
        if wlan.ready() then
            wifi_name = wifi.name
            --拿 IP 只是为了日志，失败也不能影响主流程，所以套一层 pcall
            local okip, ip = pcall(wlan.getIP)
            log.info("wlan", "got ip on wifi #" .. i, okip and tostring(ip) or "")
            break
        end
        log.warn("wlan", "wifi #" .. i .. " failed, try next")
        --这个连不上就断开重来，换下一个再试
        wlan.disconnect()
        wlan.init()
        sys.wait(5 * 1000)
    end
    if wlan.ready() then
        log.info("wlan", "ready !!")
        while true do
            while #buff > 0 do
                collectgarbage("collect")
                local sms = table.remove(buff, 1)
                local data = sms[2]
                --raw 的是系统自己产生的通知（开机通知），原样发；其余都是短信，带上发件人号码
                local text = sms.raw and data or ("SMS: " .. sms[1] .. "\n" .. data)
                local ok, code = push_text(text)
                if ok then
                    log.info("notify", "pushed", sms[1])
                else
                    log.error("notify", "push gave up", sms[1], code)
                end
            end
            if LOG_DEBUG then
                log.debug("notify", "gc", collectgarbage("count"))
            end
            log.info("notify", "wait for a new sms~")
            sys.waitUntil("SMS_ADD")--队列空了就睡，等 add() 来叫醒
        end
    else
        --所有 WiFi 都连不上，重启重来（配合看门狗形成一个自愈循环）
        log.error("wlan", "all wifi failed, reboot")
        rtos.reboot()
    end
end)


--开机通知：单独一个 task，不占推送 task。内容先塞进 buff 由推送 task 统一发，
--免得两个 HTTP 请求并发（ESP32C3 内存紧张，并发容易失败）
sys.taskInit(function()
    if BOOT_NOTICE_DELAY <= 0 then
        return--功能被关掉
    end
    sys.wait(1500)--让上面的 wifi task 先跑起来（它会先 wlan.init()）

    --1) 等联网，最多 BOOT_NOTICE_NET_TIMEOUT 秒；所有 WiFi 都连不上时上面的 task 会直接
    --   reboot，这条通知自然不发。ready 查询套 pcall：本 task 比 wlan.init() 起得早
    local function net_ready()
        if not (wlan and wlan.ready) then return false end
        local ok, r = pcall(wlan.ready)
        return (ok and r) and true or false
    end

    local waited = 0
    while not net_ready() do
        if waited >= BOOT_NOTICE_NET_TIMEOUT then
            log.warn("notify", "boot notice skipped, no network")
            return
        end
        sys.wait(1000)
        waited = waited + 1
    end

    --2) 再延时一会儿：让 main.lua 的模组配置、SIM 检查先跑完，通知里的状态才准
    sys.wait(BOOT_NOTICE_DELAY * 1000)

    --3) 拼通知正文，每项都套 pcall：任何一项取不到都不该让这条通知发不出去
    local line = {}
    line[#line + 1] = "[开机] " .. tostring(PROJECT or "sms_forwarding") .. " " .. tostring(VERSION or "")
    local okv, ver = pcall(rtos.version)
    if okv and ver then
        line[#line + 1] = "固件 " .. tostring(ver)
    end

    local ip = ""
    local oki, v = pcall(wlan.getIP)
    if oki and v then ip = tostring(v) end
    line[#line + 1] = "WiFi " .. (wifi_name ~= "" and wifi_name or "?") .. " " .. ip

    local be = backend_name()
    line[#line + 1] = "存储 " .. be .. (be == "memory" and "（配置重启会丢）" or "")
    if ip ~= "" then
        line[#line + 1] = "面板 http://" .. ip .. "/cfg"
    end

    --4) raw=true 告诉推送 task 原样发出，不要套 "SMS: 号码" 那层壳；
    --   队列项保持位置参数格式（第 1 个发件人、第 2 个内容），推送 task 按位置读
    table.insert(buff, {"boot", table.concat(line, "\n"), raw = true})
    sys.publish("SMS_ADD")--叫醒推送 task
    log.info("notify", "boot notice queued")
end)



return notify
