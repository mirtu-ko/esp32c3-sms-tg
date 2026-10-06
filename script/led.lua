--[[
状态灯（合宙 CORE ESP32C3 板载两颗 LED）
  GPIO12（丝印 D4）心跳灯：100ms 亮 / 1s 灭，确认程序还活着
  GPIO13（丝印 D5）状态灯：闪烁周期跟 led.status 走
led.status 由 main.lua 设置：1=5秒一闪(模组未响应) 2=常亮(无卡)
  3=1秒一闪(未联网) 4=0.2秒一闪(正常待机)
]]

local led = {}

--gpio.setup(引脚, 方向, 上下拉)，方向 0 = 输出
local ledStatus= gpio.setup(12, 0, gpio.PULLUP)
sys.taskInit(function()
    while true do
        ledStatus(1)
        sys.wait(100)
        ledStatus(0)
        sys.wait(1000)
    end
end)

led.status = 1
--下标即 led.status，值是"灭"的保持时间（ms）
--注意 status=2 的 1ms 不是真常亮，只是灭的时间短到看不出来
local st = {5000,1,1000,200}
local ledDoing= gpio.setup(13, 0, gpio.PULLUP)
sys.taskInit(function()
    while true do
        ledDoing(1)
        sys.wait(100)
        ledDoing(0)
        sys.wait(st[led.status])--每次循环重读状态，所以改 led.status 立刻生效
    end
end)

return led
