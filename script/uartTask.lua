--[[
Air780E 串口(AT)收发与解析

职责：把串口字节流切成行，识别两类内容，统一转成 sys.publish 事件：
  1. 我们主动发的 AT 命令的「回显」和「应答」——loopAT() 等的就是这类
  2. 模组主动上报的 URC（+CMT 来短信、+CGATT 附着状态等）

对外接口：
  air780.write(s, notNeedCRLF)  发 AT 命令；notNeedCRLF=true 时不自动补 "\r\n"（发 PDU 正文、Ctrl+Z 用）
  air780.loopAT(cmd, wait, t)   反复发 cmd 直到收到 wait 事件，返回该事件的参数

事件(topic)：
  AT_AT / AT_ATE1 / AT_UPGRADE / AT_CMGF / AT_CSCS / AT_CNMI  命令回显，收到即命令已被接受
  AT_CPIN    true=找到卡 / false=模组报 CME ERROR
  AT_CGATT   true=已附着 / false=未附着
  AT_SEND_SMS  模组回了 "> " 提示符，可以写短信正文了
  AT_CMT     phone, data(UTF-16BE), time, long, total, id, sms_id  收到短信
  UART_RECV_ID  串口静默 100ms，认为一帧收完（内部使用）

已知局限：解析到匹配行就 return，本次缓冲区剩下的行会被丢掉 —— 同一批数据里若夹着 +CMT 就永久丢这条短信；
  +CMT 后面那行直接当 PDU 解析，没校验长度/全 hex/奇偶，串口分片时会解到半截数据
]]

local air780 = {}

pdu = require("pdu")--注意：这里是全局变量，notify.lua 也依赖这个全局名，不要随手改成 local

local uartid = 1
-- 串口初始化：uartid=1 对应 ESP32C3 的 UART1，另一端接 Air780E 的 AT 口
local result = uart.setup(
    uartid,--串口id
    115200,--波特率
    8,--数据位
    1--第 4 个参数（LuatOS 文档里是校验位，这里沿用上游写法）
)

local sendQueue = {}
-- 串口超时：每收到一段数据就把 100ms 定时器往后推，静默 100ms 才认为一帧收完，
-- 然后一次性拼起来解析，避免把一条 AT 应答拆成两半处理
local uartimeout, recvReady = 100, "UART_RECV_ID"
uart.on(uartid, "receive", function(id, len)
    local s = ""
    repeat
        s = uart.read(id, len)
        if #s > 0 then
            table.insert(sendQueue, s)
            sys.timerStart(sys.publish, uartimeout, recvReady)
        end
    until s == ""
end)

--调试日志：main.lua 的 LOG_DEBUG 打开后才输出串口原始报文和 AT 收发细节
local function dlog(...)
    if LOG_DEBUG then
        log.debug("uart", ...)
    end
end

--发送AT指令
--例：air780.write("AT")        -> 实际发出 "AT\r\n"
--    air780.write(pdu, true)   -> 原样发出，不加结尾
function air780.write(s,notNeedCRLF)
    uart.write(uartid,s)
    if notNeedCRLF then
        dlog("sent raw",#s)--PDU 正文、Ctrl+Z 这类内容不整条打进日志
    else
        dlog("sent",s)
    end
    if notNeedCRLF then return end
    uart.write(uartid,"\r\n")
end

-- 一帧数据收完后的解析入口
sys.subscribe(recvReady, function()
    collectgarbage("collect")
    local s = table.concat(sendQueue)
    sendQueue = {}
    collectgarbage("collect")

    -- 模组每条内容以 "\r\n" 结尾，统一成 "\r" 再切分成逐行
    s = s:gsub("\n","\r")
    s = s:split("\r")
    collectgarbage("collect")

    while #s > 0 do
        local line = table.remove(s,1)
        --串口原始数据（含 hex）：排查问题时把 LOG_DEBUG 打开
        dlog("line",line,line:toHex())
        -- 下面是"命令回显"匹配：模组开着 ATE1，会把收到的命令原样回显一行，
        -- 所以看到回显就说明这条命令已经被模组接收了
        if line == "AT" or line == "OK" then
            sys.publish("AT_AT")
            return
        end
        if line == "ATE1" then
            sys.publish("AT_ATE1")
            return
        end
        if line == "AT+UPGRADE=\"AUTO\",0" then
            sys.publish("AT_UPGRADE")
            return
        end
        if line == "AT+CMGF=0" then
            sys.publish("AT_CMGF")
            return
        end
        if line == "AT+CSCS=\"UCS2\"" then
            sys.publish("AT_CSCS")
            return
        end
        if line == "AT+CNMI=2,2,0,0,0" then
            sys.publish("AT_CNMI")
            return
        end
        -- "> " 是发短信时的正文提示符，收到它才能把 PDU 正文写下去
        if line == "> " then
            sys.publish("AT_SEND_SMS")
            return
        end
        local urc = line:match("^%+(%w+)")
        if urc then
            if urc == "CGATT" then--基站附着状态，+CGATT: 1 表示已附着
                sys.publish("AT_CGATT",line:match("%+CGATT: *(%d)") == "1")
            elseif urc == "CMT" then--来短信了，行格式为 "+CMT: ,<PDU字节数>"
                -- len 是 PDU 字节数（不含短信中心号码），decodePDU 靠它定位数据起点
                local len = tonumber(line:match("%+CMT: *, *(%d+)"))
                repeat
                    local l = table.remove(s,1)--+CMT 的下一行就是 PDU 本体
                    if not l then break end--PDU 还在路上（回显和正文被切到两帧），等下一帧再解析
                    if #l > 0 then
                        local phone,data,time,long,total,id,sms_id = pdu.decodePDU(l,len)
                        --data 是 UTF-16BE 二进制，打进日志会是乱码，只记长度
                        log.info("sms","recv",phone,time,long and "long" or "short",
                            sms_id,total,id,"len",#data)
                        -- 抛给 main.lua 的主循环，长短信在那边攒够再拼
                        sys.publish("AT_CMT",phone,data,time,long,total,id,sms_id)
                        break
                    end
                until #s == 0
            end
        else--其他命令解析
            -- 命令应答的触发点是命令回显行（形如 AT+CPIN?），真正的答案在它后面几行
            local cmd = line:match("^AT%+(%w+)")
            if cmd then
                if cmd == "CPIN" then--检查卡：后续行含 READY=有卡，含 CME ERROR=无卡/卡异常
                    repeat
                        local l = table.remove(s,1)
                        if not l then break end--回显到了、结果还没到（被切到下一帧），等下一帧
                        if #l > 0 then
                            if l:find("READY") then--找到卡了
                                sys.publish("AT_CPIN",true)
                                return
                            elseif l:find("CME ERROR") then
                                --把模组原话打出来：SIM busy 之类的瞬时错误也走这里，
                                --而 main.lua 收到 false 就判"无卡"退出，只有看这行才能区分
                                log.error("uart","CPIN failed:",l)
                                sys.publish("AT_CPIN",false)
                                return
                            end
                        end
                    until #s == 0
                end
            end
        end
    end
end)


--反复发一条 AT 命令，直到收到对应应答为止
--参数：cmd 命令 / wait 要等的 topic / loopTime 单次等待时长（默认 200ms）
--返回值：sys.waitUntil 成功标志之后的那些参数
--  比如 AT_CGATT 返回是否附着(true/false)、AT_CPIN 返回是否有卡(true/false)，
--  一直没等到任何应答则返回 nil —— main.lua 判断"没卡"靠的就是这个 nil/false
function air780.loopAT(cmd,wait,loopTime)
    while true do
        air780.write(cmd)
        local r,r1,r2,r3 = sys.waitUntil(wait, loopTime or 200)
        if r then
            dlog("got recv",cmd)
            return r1,r2,r3
        end
    end
end




return air780
