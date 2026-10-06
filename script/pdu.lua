--[[
PDU 编解码（GSM 03.40 / 3GPP TS 23.040）
大部分代码来自：https://gitee.com/openLuat/Luat_Lua_Air724U/blob/master/script_LuaTask/lib/sms.lua

数据形态约定（容易搞混，先看这里）：
  - PDU 字符串：十六进制文本，2 个字符 = 1 字节，长度一定是偶数
  - 号码：ASCII 数字串；编成 BCD 后两个数字挤进一个字节且高低位互换（"86" -> 0x68）
  - 短信内容：本文件内部统一用"UCS2 十六进制串"中转（每字符 4 个 hex = 1 个 UTF-16BE 码元），
    最后 fromHex() 成二进制交给上层，再由 notify 用 ucs2_utf8 转 UTF-8
  - 收发两侧半字节顺序不一致是 PDU 的经典坑，改代码别凭直觉改 sub 的下标

对外接口：
  decodePDU(pdu, len)  解一条短信 -> 号码, 内容(UTF-16BE), 时间, 是否长短信, 总片数, 片号, 分组号
  encodePDU(num, data) 把 UTF-8 编成单条短信 PDU -> PDU, AT+CMGS 需要的长度
]]

local libT = {}

--号码ASCII -> BCD："+8618126324567" -> "91688121364265f7"
--第 1 个字节是号码类型（带 + 用 0x91，否则 0x81），后面是 BCD 号码，奇数位末尾补 F
local function numtobcdnum(num)
    local len, numfix, convnum = #num, "81", ""

    if num:sub(1, 1) == "+" then
        numfix = "91"
        len = len - 1
        num = num:sub(2, -1)
    end

    if len % 2 ~= 0 then --奇数位
        --每两个数字一组，输出时把高低位换过来
        for i = 1, (len - (len % 2)) / 2 do
            convnum = convnum .. num:sub(i * 2, i * 2) .. num:sub(i * 2 - 1, i * 2 - 1)
        end
        convnum = convnum .. "F" .. num:sub(len, len)--最后一个数字配 F：先写 F 再写数字，即偶数位在前
    else --偶数位
        for i = 1, (len - (len % 2)) / 2 do
            convnum = convnum .. num:sub(i * 2, i * 2) .. num:sub(i * 2 - 1, i * 2 - 1)
        end
    end

    return numfix .. convnum
end

--8位编码（DCS=0x04）转 UCS2 十六进制串：每字节前补 "00"，当 Latin-1 处理。返回 串, 字节数
local function gsm8bitdecode(data)
    local ucsdata, lpcnt = "", #data / 2
    for i = 1, lpcnt do
        ucsdata = ucsdata .. "00" .. data:sub((i - 1) * 2 + 1, i * 2)
    end
    return ucsdata, lpcnt
end


--GSM 7bit 默认字符表：下标是 7bit 值，取值是该字符的 Unicode 码点
local Charmap = {[0] = 0x40, 0xa3, 0x24, 0xa5, 0xe8, 0xE9, 0xF9, 0xEC, 0xF2, 0xC7, 0x0A, 0xD8, 0xF8, 0x0D, 0xC5, 0xE5
    , 0x0394, 0x5F, 0x03A6, 0x0393, 0x039B, 0x03A9, 0x03A0, 0x03A8, 0x03A3, 0x0398, 0x039E, 0x1B, 0xC6, 0xE5, 0xDF, 0xA9
    , 0x20, 0x21, 0x22, 0x23, 0xA4, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F
    , 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    , 0xA1, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F
    , 0X50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0xC4, 0xD6, 0xD1, 0xDC, 0xA7
    , 0xBF, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F
    , 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0xE4, 0xF6, 0xF1, 0xFC, 0xE0}

--GSM 7bit 扩展字符表：7bit 值 0x1B(27) 是转义标志，其后一个字节再查这张表
local Charmapctl = {[10] = 0x0C, [20] = 0x5E, [40] = 0x7B, [41] = 0x7D, [47] = 0x5C, [60] = 0x5B, [61] = 0x7E
    , [62] = 0x5D, [64] = 0x7C, [101] = 0xA4}

--7bit 解码（DCS=0x00，最多 160 字符）：每 8 位塞 7 位、剩 1 位留给下一个字符，
--靠 nbyte（本字节已用掉几位）和 nleft（上字节剩下的高位）跨字节拼字符。
--longsms=true 时正文前有 UDH，7bit 起点偏移 1 bit，必须走特殊分支。返回 UCS2串, 字符数
local function gsm7bitdecode(data, longsms)
    local ucsdata, lpcnt, tmpdata, resdata, nbyte, nleft, ucslen, olddat = "", #data / 2, 0, 0, 0, 0, 0

    if longsms then
        --长短信：UDH 占了 6/7 字节，正文的第一个 7bit 要从第 1 位开始取
        tmpdata = tonumber("0x" .. data:sub(1, 2))
        resdata = tmpdata >> 1
        if olddat == 27 then
            if Charmapctl[resdata] then --特殊字符
                olddat, resdata = resdata, Charmapctl[resdata]
                ucsdata = ucsdata:sub(1, -5)--转义字符本身不该输出，把它从结果里删掉
            else
                olddat, resdata = resdata, Charmap[resdata]
            end
        else
            olddat, resdata = resdata, Charmap[resdata]
        end
        ucsdata = ucsdata .. string.format("%04X", resdata)
    else
        tmpdata = tonumber("0x" .. data:sub(1, 2))
        resdata = ((tmpdata<<nbyte)|nleft)&0x7f
        if olddat == 27 then
            if Charmapctl[resdata] then --特殊字符
                olddat, resdata = resdata, Charmapctl[resdata]
                ucsdata = ucsdata:sub(1, -5)
            else
                olddat, resdata = resdata, Charmap[resdata]
            end
        else
            olddat, resdata = resdata, Charmap[resdata]
        end
        ucsdata = ucsdata .. string.format("%04X", resdata)

        nleft = tmpdata >> (7 - nbyte)--本字节用不完的高位，留给下一个字符
        nbyte = nbyte + 1
        ucslen = ucslen + 1
    end

    for i = 2, lpcnt do
        tmpdata = tonumber("0x" .. data:sub((i - 1) * 2 + 1, i * 2))
        if tmpdata == nil then break end
        resdata = ((tmpdata<<nbyte)|nleft)&0x7f
        if olddat == 27 then
            if Charmapctl[resdata] then --特殊字符
                olddat, resdata = resdata, Charmapctl[resdata]
                ucsdata = ucsdata:sub(1, -5)
            else
                olddat, resdata = resdata, Charmap[resdata]
            end
        else
            olddat, resdata = resdata, Charmap[resdata]
        end
        ucsdata = ucsdata .. string.format("%04X", resdata)

        nleft = tmpdata >> (7 - nbyte)
        nbyte = nbyte + 1
        ucslen = ucslen + 1

        if nbyte == 7 then
            --凑满 7 位后，本字节剩下的那一位正好就是下一个字符，单独补一个
            if olddat == 27 then
                if Charmapctl[nleft] then --特殊字符
                    olddat, nleft = nleft, Charmapctl[nleft]
                    ucsdata = ucsdata:sub(1, -5)
                else
                    olddat, nleft = nleft, Charmap[nleft]
                end
            else
                olddat, nleft = nleft, Charmap[nleft]
            end
            ucsdata = ucsdata .. string.format("%04X", nleft)
            nbyte, nleft = 0, 0
            ucslen = ucslen + 1
        end
    end

    return ucsdata, ucslen
end

--UTF-16BE 二进制 -> UTF-8；只处理基本平面（BMP），不含代理对，emoji 这类会被截断
function libT.ucs2_utf8(s)
    local temp = {}
    for i=1,#s,2 do
        local d1,d2 = s:byte(i),s:byte(i+1)
        if d1 == 0 and d2 <= 0x7f then  --不大于0x007F
            table.insert(temp,string.char(d2))
        elseif d1 < 0x07 then  --不大于0x07FF  00000aaa bbbbbbbb ==> 110aaabb 10bbbbbb
            table.insert(temp,string.char(0xc0+(d1<<2)+(d2>>6), 0x80+(d2&0x3f)))
        else    --aaaaaaaa bbbbbbbb ==> 1110aaaa 10aaaabb 10bbbbbb
            table.insert(temp,string.char(0xe0 + (d1>>4), 0x80 + ((d1&0x0f)<<2) + (d2>>6), 0x80 + (d2&0x3f)))
        end
    end
    return table.concat(temp)
end

--UTF-8 -> UCS2 十六进制串（编码方向，给 encodePDU 用）
--已知问题：4 字节分支（emoji 等）的码点超过 0xFFFF，后面 %04X 会输出 5 位以上，拼进 PDU 就是错的
function libT.utf8_ucs2(s)
    local ucsdata = ""
    local i = 1
    while i <= #s do
        local c = string.byte(s, i)
        local resdata = 0
        local nbyte = 0
        if c < 128 then
            resdata = c
            nbyte = 1
        elseif c < 224 then
            resdata = (c - 192) * 64 + (string.byte(s, i + 1) - 128)
            nbyte = 2
        elseif c < 240 then
            resdata = (c - 224) * 4096 + (string.byte(s, i + 1) - 128) * 64 + (string.byte(s, i + 2) - 128)
            nbyte = 3
        elseif c < 248 then
            resdata = (c - 240) * 262144 + (string.byte(s, i + 1) - 128) * 4096 + (string.byte(s, i + 2) - 128) * 64 + (string.byte(s, i + 3) - 128)
            nbyte = 4
        end
        ucsdata = ucsdata .. string.format("%04X", resdata):fromHex()
        i = i + nbyte
    end
    return ucsdata
end

--BCD -> 号码ASCII ："91688121364265f7" -> "+8618126324567"
--开头两字符是号码类型：91=国际（补 +）、81=国内、D0=字母发件人（按 GSM 7bit 解）；
--sender_address_length_raw 是号码原始数字个数，字母发件人靠它算有效字符数
local function bcdnumtonum(num, sender_address_length_raw)
    local len, numfix, convnum = #num, "", ""
    if len % 2 ~= 0 then log.error("pdu","bad bcd number:",num) return end
    if num:sub(1, 2) == "91" then numfix = "+" end
    if num:sub(1, 2):upper() == "D0" then
        --字母发件人（比如银行/运营商用英文名当发件人）：号码段其实是 7bit 编码的文本
        convnum = gsm7bitdecode(num:sub(3), false)
        log.debug("pdu", "GSM-7 decoded, data: \""..convnum.."\"")
        convnum = convnum:fromHex()
        local decoded_number_in_utf8 = libT.ucs2_utf8(convnum)
        log.debug("pdu", "number in UTF-8: "..decoded_number_in_utf8)

        -- 取出decoded_number_in_utf8中的有效字符 = sender_address_length_raw * 4 / 7 向下取整
        decoded_number_in_utf8 = decoded_number_in_utf8:sub(1, math.floor(sender_address_length_raw * 4 / 7))

        return decoded_number_in_utf8
    end
    --丢掉开头的号码类型字节，剩下的半字节两两互换还原成数字
    len, num = len - 2, num:sub(3, -1)
    for i = 1, (len - (len % 2)) / 2 do
        convnum = convnum .. num:sub(i * 2, i * 2) .. num:sub(i * 2 - 1, i * 2 - 1)
    end
    if convnum:sub(len, len) == "f" or convnum:sub(len, len) == "F" then--数字个数为奇数时末尾的补位 F 要去掉
        convnum = convnum:sub(1, -2)
    end
    return numfix .. convnum
end

--解析PDU短信。去掉短信中心号码后的结构（每段都是十六进制字符）：
--  1-2   FO       首字节：bit0-1 短信类型(00=接收)，bit2(0x04)=1 表示带 UDH（长短信）
--  3-4   地址长度  对方号码数字个数        5-6   号码类型 91=国际/81=国内/D0=字母发件人
--  7-..  号码      BCD，奇数位末尾补 F
--  ...   TP-PID   协议标识（一般 00）     ...   TP-DCS  编码：00=7bit, 04=8bit, 08=UCS2
--  ...   TP-SCTS  时间戳 7 字节 YY MM DD hh mm ss TZ，每字节半字节互换
--  ...   TP-UDL   用户数据长度            ...   TP-UD   用户数据（带 UDH 时开头是分片信息）
function libT.decodePDU(pdu,len)
    collectgarbage("collect")
    local offset = 5
    local addlen, addnum, flag, dcs, tz, txtlen, fo, longsms
    pdu = pdu:sub((#pdu / 2 - len) * 2 + 1)--PDU数据，不包括短信息中心号码
    fo = tonumber("0x" .. pdu:sub(1, 1))--PDU短信首字节的高4位,第6位为数据报头标志位
    if fo & 0x4 ~= 0 then--0x04 是 UDHI 位，置位说明带 UDH，即长短信
        longsms = true
    end
    addlen = tonumber(string.format("%d", "0x" .. pdu:sub(3, 4)))--回复地址数字个数
    local sender_address_length_raw = addlen

    addlen = addlen % 2 == 0 and addlen + 2 or addlen + 3 --加上号码类型2位（5，6）or 加上号码类型2位（5，6）和1位F

    offset = offset + addlen

    addnum = pdu:sub(5, 5 + addlen - 1)
    local convnum = bcdnumtonum(addnum, sender_address_length_raw)

    flag = tonumber(string.format("%d", "0x" .. pdu:sub(offset, offset + 1)))--协议标识 (TP-PID)
    offset = offset + 2
    dcs = tonumber(string.format("%d", "0x" .. pdu:sub(offset, offset + 1)))--用户信息编码方式 Dcs=8，表示短信存放的格式为UCS2编码
    offset = offset + 2
    tz = pdu:sub(offset, offset + 13)--时区7个字节
    offset = offset + 14
    txtlen = tonumber(string.format("%d", "0x" .. pdu:sub(offset, offset + 1)))--短信文本长度
    offset = offset + 2
    local data = pdu:sub(offset, offset + txtlen * 2 - 1)--短信文本

    if LOG_DEBUG then
        --排查解析问题时用：把首字节和各字段长度一次打出来
        log.debug("pdu", "fo/dcs/pid/txtlen", fo, dcs, flag, txtlen,
            "longsms", longsms, "pdulen", #pdu, "len", len)
    end

    local sms_id, total, idx
    if longsms then
        --UDH 格式：[UDHL][IEI][IEDL][分片信息...]
        --此处 data:sub(5,6) 取的是 IEDL：3 = 8bit 参考号(1字节)，4 = 16bit 参考号(2字节)
        --注意：没有校验 IEI 是否为 0x00（拼接），若换成其它 UDH 类型，下面三个变量就是 nil，
        --      而 main.lua 需要它们非空，所以那边做了守护
        if tonumber("0x" .. data:sub(5, 6)) == 3 then
            sms_id, total, idx = tonumber("0x" .. data:sub(7, 8)), tonumber("0x" .. data:sub(9, 10)), tonumber("0x" .. data:sub(11, 12))
            data = data:sub(13, -1)--去掉报头6个字节
        elseif tonumber("0x" .. data:sub(5, 6)) == 4 then
            sms_id, total, idx = tonumber("0x" .. data:sub(7, 10)), tonumber("0x" .. data:sub(11, 12)), tonumber("0x" .. data:sub(13, 14))
            data = data:sub(15, -1)--去掉报头7个字节
        end
    end

    if dcs == 0x00 then --7bit encode
        local newlen
        data, newlen = gsm7bitdecode(data, longsms)
        if newlen > txtlen then--7bit 会有对齐填充位，多解出来的字符要裁掉
            data = data:sub(1, txtlen * 4)
        end
    elseif dcs == 0x04 then --8bit encode
        data, txtlen = gsm8bitdecode(data)
    end
    --dcs=0x08(UCS2) 时上面两个分支都不进，data 本身就是 UCS2 十六进制串
    data = data:fromHex()--还是要转回bin数据的

    --时间戳 7 字节：每个字节的高低半字节互换后拼成 YY/MM/DD,hh:mm:ss
    local t = ""
    for i = 1, 6 do
        t = t .. tz:sub(i * 2, i * 2) .. tz:sub(i * 2 - 1, i * 2 - 1)

        if i <= 3 then
            t = i < 3 and (t .. "/") or (t .. ",")
        elseif i < 6 then
            t = t .. ":"
        end
    end

    --最后一个字节是时区：单位 1/4 小时，bit3 是符号位，拨掉符号位后还要把半字节换回来
    local timezone = tz:sub(13,14)
    timezone = tonumber(timezone, 16)
    local tzNegative = (timezone & 0x08) == 0x08
    timezone = timezone & 0xF7 -- 按位与 1111 0111
    timezone = tonumber(string.format("%x", timezone):sub(2,2) .. string.format("%x", timezone):sub(1,1)) * 15 / 60

    if tzNegative then
        timezone = -timezone
    end
    t = t..string.format("%+03d",timezone)--形如 "26/10/06,19:14:31+32"，时区是 1/4 小时数

    return convnum, data, t,longsms, total, idx, sms_id
end

--生成单条短信的 PDU（入参 UTF-8，返回 PDU 与长度）。组装的是 SMS-SUBMIT：
--  00 短信中心长度=0（用模组里配的默认短信中心）  11 首字节(SMS-SUBMIT + 相对格式有效期)
--  10 消息参考号(随便给)  <numlen> 目标号码长度  BCD号码(带类型字节)
--  00 TP-PID   08 TP-DCS=UCS2   00 有效期   <datalen> 用户数据长度   <data> 用户数据
--返回值第二个是 AT+CMGS 要填的长度 = PDU 总字节数 - 1（短信中心那 1 字节不计入）
--注意：内容超过 140 字节会被截断成单条，截断后必须重算 datalen，否则 UDL 与实际数据不一致
function libT.encodePDU(num,data)
    data = libT.utf8_ucs2(data):toHex()
    local numlen, datalen, pducnt, pdu, pdulen, udhi = string.format("%02X", #num), #data / 2, 1, "", "", ""
    if datalen > 140 then--短信内容太长啦
        data = data:sub(1, 140 * 2)
        datalen = #data / 2--截断后必须重算，否则 UDL 会比实际数据长，生成非法 PDU
    end
    datalen = string.format("%02X", datalen)
    pdu = "001110" .. numlen .. numtobcdnum(num) .. "000800" .. datalen .. data
    return pdu, #pdu // 2 - 1
end

return libT
