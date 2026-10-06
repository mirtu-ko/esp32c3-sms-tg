--[[
局域网 Web 配置面板（httpsrv）

作用：设备联网后浏览器打开 http://<设备IP>/cfg 看状态、改配置、看最近短信。
接口： GET /cfg 页面骨架 / GET /cfg.js 页面脚本 / GET /api/status 运行状态 /
      GET /api/config 当前配置 / POST /api/config 保存（token、chat、tag、重试参数）/
      GET /api/sms 最近短信 / POST /api/test 测试推送 / POST /api/reboot 重启。
安全：不做鉴权，同局域网谁都能访问，别把 80 端口映射到公网。

WiFi 为什么不给改：改 WiFi 必须重启才生效（notify 只在启动时读一次列表），而当前固件不带
KV 库、配置落不了盘，重启就回默认值 —— 改了等于白改；万一改成连不上的 WiFi，重启后会陷入
无限重启循环，只能重烧脚本救。所以只做只读展示，要改就改设备里的 config.lua 再重下脚本。

三条 httpsrv 的坑（都真踩过）：
  1. 页面要挂 /cfg 而不是 / —— 对 "/" 和 "*.html"，httpsrv 会先去 luadb 找同名静态文件。
  2. 单个响应整体上限 8192 字节（含响应头，见 luat_http.h 的 HTTP_RESP_BUFF_SIZE），超出
     直接切掉且不报错。整页 9059 字节只发出 7827（= 8192 减 365 字节响应头），截断点落在
     <script> 里 → 浏览器拿到未闭合的 JS，整段不执行、页面空白、连 /api 请求都发不出。
     所以 JS 拆成 /cfg.js、/api/sms 按字节数截断；加东西前先看启动日志打的两段字节数。
  3. 同一时间只服务 1 个客户端连接，所以外部资源越少越好（CSS 内嵌在骨架里）。

铁律：面板页面里不许出现「连着两个减号」。LuatOS/Luatools 下载脚本时会做文本预处理，把
「连着两个减号」到行尾的内容整段删掉、去首尾空白、删空行，而且不认长字符串 —— 嵌在页面里的
也会被删。踩过：CSS 的 var(...) 被砍断、JS 里的 i 自减被砍成 i（导致 JS 语法错误 → load()
不执行 → 页面空白）。所以 CSS 写死颜色值、循环写 i = i - 1；下面的哨兵自检就是防这个的。
]]

local config = _G.config or {}
local notify = _G.notify

local PORT = 80
local JSON_HDR = {["Content-Type"] = "application/json; charset=utf-8"}
local HTML_HDR = {["Content-Type"] = "text/html; charset=utf-8"}
local JS_HDR = {["Content-Type"] = "application/javascript; charset=utf-8",
                ["Cache-Control"] = "no-cache"}

--面板上显示的固件版本
local FW = "unknown"
if rtos and rtos.version then
    local ok, v = pcall(rtos.version)
    if ok and v then FW = tostring(v) end
end

--在线时长（秒）：1s 循环定时器累加。esp32c3 没有 RTC 电池，os.time() 不可靠
local uptime = 0
sys.timerLoopStart(function()
    uptime = uptime + 1
end, 1000)

----------------------------------------------------------------------
-- 页面：写成两个字面量，各自就是一次响应，加载期不做任何字符串拼接。
-- 原来用 PAGE:match + PAGE:gsub 从整页里拆，会在 8.3KB 的整页之外再复制出 4.9KB + 3.5KB，
-- V1004 的 Lua 堆只有 96KB，实测直接 OOM（not enough memory for buffer allocation）。
-- 这个长字符串里绝对不能出现那两个减号，见文件头注意4。
----------------------------------------------------------------------
local PAGE_SHELL = [==[<!DOCTYPE html>
<html lang=zh-CN><head>
<meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>短信转发器</title>
<style>
*{box-sizing:border-box}
body{margin:0;background:#f5f6f8;color:#1f2329;font:14px/1.6 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;word-break:break-all}
.wrap{max-width:780px;margin:0 auto;padding:14px}
h1{font-size:17px;margin:0 0 2px}
.sub{color:#8a9099;font-size:12px;margin-bottom:12px}
.card{background:#fff;border:1px solid #e3e6ea;border-radius:10px;padding:14px;margin-bottom:12px}
.card h2{font-size:13px;margin:0 0 10px;color:#3a4149;font-weight:600}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(112px,1fr));gap:8px}
.kv{background:#fafbfc;border:1px solid #e3e6ea;border-radius:8px;padding:7px 9px}
.kv b{display:block;font-size:11px;color:#8a9099;font-weight:400}
.kv span{font-size:14px;font-weight:600}
label{display:block;font-size:12px;color:#8a9099;margin:9px 0 3px}
input{width:100%;padding:8px 10px;border:1px solid #e3e6ea;border-radius:8px;font-size:14px;color:#1f2329;font-family:inherit}
.row{display:flex;gap:8px;align-items:flex-end;margin-top:9px}
.row .f{flex:1;min-width:0}
button{border:0;border-radius:8px;padding:9px 13px;font-size:13px;background:#2b7de9;color:#fff;cursor:pointer;font-family:inherit}
button.gray{background:#eef0f3;color:#3a4149}
button.bad{background:#fdecec;color:#d93026}
.wlist{font-size:13px}
.wlist div{border-top:1px solid #e3e6ea;padding:7px 0}
.wlist div:first-child{border-top:0}
.msg{border-radius:8px;padding:8px 10px;font-size:12px;margin-top:10px;display:none;white-space:pre-wrap}
.msg.on{display:block}
.msg.ok{background:#eaf7ef;color:#12a150}
.msg.err{background:#fdecec;color:#d93026}
ul.sms{list-style:none;margin:0;padding:0}
ul.sms li{border-top:1px solid #e3e6ea;padding:8px 0;font-size:13px}
ul.sms li:first-child{border-top:0}
ul.sms .h{color:#8a9099;font-size:11px;margin-bottom:2px}
.tip{color:#8a9099;font-size:12px;margin-top:8px}
</style>
</head><body>
<div class=wrap>
<h1>短信转发器</h1>
<div class=sub id=sub>读取中…（一直停着说明面板脚本没加载，看 F12 Console）</div>
<div class=card><h2>运行状态</h2><div class=grid id=stat></div></div>
<div class=card><h2>WiFi（只支持 2.4G，按顺序逐个尝试）</h2><div id=wifi class=wlist></div><div class=tip>只读，要改请改设备里的 config.lua 再重下脚本（改完须重启）。</div></div>
<div class=card><h2>Telegram 推送</h2><label>Bot Token</label><input id=token autocomplete=off><label>Chat ID</label><input id=chat></div>
<div class=card><h2>指令口令 / 推送参数</h2><label>指令口令 tag：<b>C&lt;tag&gt;REBOOT</b> 重启，<b>C&lt;tag&gt;SEND号码 内容</b> 发短信</label><input id=tag><div class=row><div class=f><label>推送重试次数</label><input id=pushMax></div><div class=f><label>重试间隔（毫秒）</label><input id=pushGap></div></div></div>
<div class=card><button onclick=save()>保存</button> <button class=gray onclick=test()>测试推送</button> <button class=gray onclick=load()>刷新</button> <button class=bad onclick=reboot()>重启设备</button><div class=msg id=msg></div></div>
<div class=card><h2>最近收到的短信</h2><ul class=sms id=sms></ul></div>
</div>

<script src=/cfg.js></script>
</body>
</html>
]==]

local PAGE_JS = [==[/* 下一行是哨兵：能执行说明整段 JS 完整加载并解析成功，否则页面顶部那句会一直停在"读取中"。
只用块注释、不用双斜杠，理由见本文件文件头。 */
$('sub').textContent = '面板脚本已加载，正在读取设备状态…';
var timer = null;

function $(id){return document.getElementById(id);}
function esc(s){return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}

function show(t, ok){
  var m = $('msg');
  m.textContent = t;
  m.className = 'msg on ' + (ok ? 'ok' : 'err');
  if (ok){ clearTimeout(timer); timer = setTimeout(function(){ m.className = 'msg'; }, 5000); }
}

function api(p, o){
  return fetch(p, o).then(function(r){ return r.text(); }).then(function(t){
    try { return JSON.parse(t); } catch(e){ throw new Error('接口返回异常：' + t.slice(0,80)); }
  });
}

function fmtUp(s){
  s = s || 0;
  if (s < 60) return s + ' 秒';
  if (s < 3600) return Math.floor(s/60) + ' 分';
  return Math.floor(s/3600) + ' 时 ' + Math.floor(s%3600/60) + ' 分';
}

function kv(k, v){return '<div class=kv><b>'+k+'</b><span>'+v+'</span></div>';}

function showWifi(l){
  var h = '';
  for (var i = 0; l && i < l.length; i = i + 1){
    h += '<div>' + (i+1) + '. ' + esc(l[i].name) + ' · 密码 ' + esc(l[i].password) + '</div>';
  }
  $('wifi').innerHTML = h || '<div class=tip>没有配置 WiFi</div>';
}

function load(){
  api('/api/status').then(function(s){
    if (!s.ok) return;
    $('sub').textContent = '设备 ' + (s.ip||'-') + ' · 固件 ' + s.fw + ' · 存储 ' + (s.backend||'?') + ' · 面板端口 ' + s.port;
    $('stat').innerHTML = kv('WiFi', s.ssid||'未连接') + kv('信号', s.rssi ? s.rssi + ' dBm' : '-') +
      kv('待推送', s.queue + ' 条') + kv('在线', fmtUp(s.up)) + kv('上次推送', s.lastPush) + kv('调试日志', s.debug ? '开' : '关');
  }).catch(function(e){ $('sub').textContent = '读状态失败：' + e.message; });

  api('/api/config').then(function(c){
    if (!c.ok) return;
    $('token').value = c.token || '';
    $('chat').value = c.chat || '';
    $('tag').value = c.tag || '';
    $('pushMax').value = c.pushMax;
    $('pushGap').value = c.pushGap;
    showWifi(c.wifi);
  }).catch(function(){});

  api('/api/sms').then(function(r){
    if (!r.ok) return;
    var h = '', l = r.list || [];
    if (!l.length) h = '<li class=h>还没有收到短信</li>';
    /* 倒序显示，新的在上面。这里必须写 i = i - 1，不能用递减简写（会被脚本预处理砍坏） */
    for (var i = l.length - 1; i >= 0; i = i - 1){
      h += '<li><div class=h>' + esc(l[i].phone) + ' · ' + esc(l[i].time || '时间未知') + '</div>' + esc(l[i].text) + '</li>';
    }
    $('sms').innerHTML = h;
  }).catch(function(){});
}

function save(){
  api('/api/config', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({
    token: $('token').value.trim(), chat: $('chat').value.trim(), tag: $('tag').value.trim(),
    pushMax: $('pushMax').value, pushGap: $('pushGap').value
  })}).then(function(r){
    if (!r.ok){ show('保存失败：' + (r.err || '未知错误'), false); return; }
    var m = '已保存，立即生效';
    if (!r.persist) m += '\n注意：当前固件缺 KV 库，配置只存在内存里，重启设备会回到出厂默认值';
    if (r.warn) m += '\n' + r.warn;
    show(m, true);
    load();
  }).catch(function(e){ show('保存失败：' + e.message, false); });
}

function test(){
  api('/api/test', {method: 'POST'}).then(function(r){
    show(r.ok ? '已发起测试推送，几秒后看 Telegram' : ('失败：' + r.err), r.ok);
  }).catch(function(e){ show('失败：' + e.message, false); });
}

function reboot(){
  if (!confirm('确定重启设备？')) return;
  api('/api/reboot', {method: 'POST'}).then(function(){ show('重启指令已下发', true); });
}

load();
]==]

--启动时把两段的大小打出来：以后改面板，对着这行确认都没超过 ~7.8KB
log.info("web", "panel page", #PAGE_SHELL, "bytes, js", #PAGE_JS,
    "bytes, lua mem", math.floor(collectgarbage("count")), "KB")

--哨兵自检：脚本预处理会删掉那两个减号到行尾的内容（见文件头注意4），一旦混进页面里
--JS 就会语法错误、整个面板看起来是空的。这两个检查能立刻报警。
if not PAGE_JS:find("load();%s*$") then
    log.error("web", "PAGE_JS truncated! check for double-dash inside the page")
end
if not PAGE_SHELL:find("background:#f5f6f8", 1, true) then
    log.error("web", "PAGE_SHELL truncated! check for double-dash inside the page")
end

----------------------------------------------------------------------
-- 小工具
----------------------------------------------------------------------

--URL 解码（%XX 和 +）。LuatOS 只保证有 string.urlEncode，解码得自己实现
local function urldecode(s)
    if not s then return "" end
    s = s:gsub("+", " ")
    s = s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return s
end

--把 "/api/sms?n=20" 拆成 path 和参数表（参数目前没用到，留着方便以后加接口）
local function qparse(uri)
    local path, q = (uri or "/"):match("^([^?]*)%??(.*)$")
    local args = {}
    for k, v in (q or ""):gmatch("([%w_%-%.]+)=([^&]*)") do
        args[k] = urldecode(v)
    end
    return path or "/", args
end

local function jbody(t)
    local ok, s = pcall(json.encode, t)
    if ok then return s end
    return '{"ok":false,"err":"encode failed"}'
end

local function getip()
    if wlan and wlan.getIP then
        local ok, ip = pcall(wlan.getIP)
        if ok and ip then return tostring(ip) end
    end
    return "-"
end

local function last_push_text()
    local lp = notify and notify.lastPush
    if type(lp) ~= "table" then return "还没推过" end
    return (lp.ok and "成功 " or "失败 ") .. tostring(lp.code)
end

----------------------------------------------------------------------
-- 请求处理
----------------------------------------------------------------------
local function handler(client, method, uri, headers, body)
    local path = qparse(uri)
    method = method or "GET"

    if path == "/cfg" or path == "/" or path == "/index.html" then
        return 200, HTML_HDR, PAGE_SHELL
    elseif path == "/cfg.js" then
        return 200, JS_HDR, PAGE_JS--单独一个响应，避免整页超过 8KB 被截断
    end

    if path == "/api/status" then
        local rssi = nil
        if wlan and wlan.getInfo then
            local ok, info = pcall(wlan.getInfo)
            if ok and type(info) == "table" then rssi = info.rssi end
        end
        local ssid = ""
        if notify and notify.wifiName then ssid = notify.wifiName() end
        return 200, JSON_HDR, jbody({
            ok = true,
            ip = getip(),
            port = PORT,
            fw = FW,
            ver = VERSION,
            backend = config.backend and config.backend() or "?",
            ssid = ssid,
            rssi = tonumber(rssi) or 0,
            queue = notify and notify.queueLen and notify.queueLen() or -1,
            up = uptime,
            debug = LOG_DEBUG and true or false,
            lastPush = last_push_text()
        })

    elseif path == "/api/config" then
        if method == "POST" then
            local ok, t = pcall(json.decode, body or "")
            if not ok or type(t) ~= "table" then
                return 200, JSON_HDR, jbody({ok = false, err = "bad json body"})
            end
            --WiFi 一律不接受：面板只读展示（原因见文件头）。这里丢弃字段，
            --防止有人直接 POST 改 WiFi —— 改了无法持久化，重启还可能连不上网陷入重启循环
            t.wifi = nil
            local saved, hint = config.set and config.set(t)
            log.info("web", "config saved", saved, "from", client)
            return 200, JSON_HDR, jbody({ok = true, persist = saved and true or false, warn = hint})
        end
        local c = config.all and config.all() or {}
        return 200, JSON_HDR, jbody({
            ok = true,
            wifi = c.wifi or {},
            token = c.token or "",
            chat = c.chat or "",
            tag = c.tag or "",
            pushMax = c.pushMax or 10,
            pushGap = c.pushGap or 5000
        })

    elseif path == "/api/sms" then
        --响应整体上限 8192 字节，这里按累计字节数截断（不是按条数）：
        --20 条 × 300 字的中文能到 18KB，超了会被切出一个非法 JSON，前端直接报错
        local src = (notify and notify.history and notify.history()) or {}
        local picked, used = {}, 0
        for i = #src, 1, -1 do--从最新的往回取
            local one = #tostring(src[i].phone) + #tostring(src[i].text) + 64
            if used + one > 2000 then break end
            used = used + one
            table.insert(picked, src[i])
        end
        --picked 是"新→旧"，翻回页面期望的"旧→新"顺序
        local list = {}
        for i = #picked, 1, -1 do
            list[#list + 1] = picked[i]
        end
        return 200, JSON_HDR, jbody({ok = true, list = list})

    elseif path == "/api/test" then
        if notify and notify.test then notify.test() end
        return 200, JSON_HDR, jbody({ok = true})

    elseif path == "/api/reboot" then
        log.warn("web", "reboot requested from", client)
        sys.timerStart(rtos.reboot, 1500)
        return 200, JSON_HDR, jbody({ok = true})
    end

    return 404, JSON_HDR, jbody({ok = false, err = "not found", path = path})
end

----------------------------------------------------------------------
-- 起服务：等 WiFi 拿到 IP 之后绑 80 端口
----------------------------------------------------------------------
local started, tries = false, 0

local function try_start()
    if not httpsrv then
        log.error("web", "firmware has no httpsrv lib, panel disabled")
        return false
    end
    --新版 httpsrv 要指定网卡（socket.LWIP_STA），老版是两参数，两种都试一次
    local ok, res
    if _G.socket and socket.LWIP_STA then
        ok, res = pcall(httpsrv.start, PORT, handler, socket.LWIP_STA)
    else
        ok, res = pcall(httpsrv.start, PORT, handler)
    end
    if ok and res ~= false then return true end

    local ok2, res2 = pcall(httpsrv.start, PORT, handler)
    if ok2 and res2 ~= false then return true end

    log.error("web", "httpsrv.start failed", tostring(res), tostring(res2))
    return false
end

sys.taskInit(function()
    sys.wait(2000)--让 notify 的 wifi 任务先起来
    local lastIp = nil
    while true do
        if wlan and wlan.ready and wlan.ready() then
            if not started and tries < 3 then
                tries = tries + 1
                started = try_start()
            end
            local ip = getip()
            if started and ip ~= lastIp then
                lastIp = ip
                log.info("web", "配置面板 http://" .. ip .. "/cfg")
            end
            sys.wait(10000)--已联网就 10s 巡检一次（IP 可能变）
        else
            --没联网就睡，等 WiFi 事件；最长 30s 醒一次重新判断
            sys.waitUntil("IP_READY", 30000)
        end
    end
end)
