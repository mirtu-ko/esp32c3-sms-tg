# esp32c3-sms-tg · 短信转发器（ESP32C3 + Air780E · LuatOS）

基于 [chenxuuu/sms_forwarding](https://github.com/chenxuuu/sms_forwarding) 改造，硬件方案与接线沿用[原教程](https://www.chenxublog.com/2022/10/28/19-9-sms-forwarding-air780e-esp32c3.html)。
推送通道仅保留 Telegram，另实现 Web 配置面板、远程指令与开机通知。

## 功能

- 短信实时转发至 Telegram，支持中文与长短信自动拼接
- Web 面板：查看运行状态、修改配置、查看最近短信
- 远程指令：通过短信触发设备重启，或指令模组发送短信
- 开机通知：联网后推送固件版本、WiFi、IP 与面板地址
- 异常自愈：未插卡、未联网、WiFi 全部连接失败时自动重试，不退出

## 硬件

主控为合宙 CORE ESP32C3，通信模组为 Air780E（AT 固件）。ESP32C3 的 UART1 接 Air780E 的 AT 口，115200。
板载 GPIO12 心跳灯、GPIO13 状态灯，SIM 卡插在 Air780E 上。

## 目录结构

```
script/        LuatTools「下载脚本」的目标目录
               main.lua 主程序 / uartTask.lua AT 串口收发 / pdu.lua PDU 编解码
               notify.lua WiFi 连接、推送、指令、开机通知 / webcfg.lua 面板 / led.lua 状态灯
               config.lua.example 配置模板，复制为 config.lua 后填值（不入版本库）
firmware/      固件
preview/       面板离线预览，不下载到设备
```

## 上手

1. 刷写固件：ESP32C3 使用 `firmware/LuatOS-SoC_V1004_ESP32C3.soc`，Air780E 使用 `firmware/AirM2M_780E_V1179_LTE_AT.binpkg`
2. 将 `script/config.lua.example` 复制为 `script/config.lua` 并填写实际值
3. 使用 LuatTools「下载脚本」将 `script/` 目录下载至设备

## 配置

配置项位于 `script/config.lua` 的 `DEFAULTS` 表：

| 键 | 含义 | 默认 | 说明 |
|---|---|---|---|
| `wifi` | WiFi 列表，按顺序逐个尝试 | — | 仅支持 2.4G；修改后需重启生效 |
| `token` | Telegram Bot Token | — | 由 [@BotFather](https://t.me/BotFather) 申请 |
| `chat` | Telegram Chat ID | — | 由 [@userinfobot](https://t.me/userinfobot) 获取 |
| `tag` | 短信指令口令 | — | 仅允许字母、数字与下划线 |
| `pushMax` | 推送重试次数 | `10` | 1–30 |
| `pushGap` | 重试间隔（毫秒） | `5000` | 500–60000 |

- `token` / `chat` / `tag` / 重试参数为即时读取，面板保存后立即生效；`wifi` 仅启动时读取一次，修改后需重启。
- 配置不持久：启动日志输出 `backend memory` 表示当前固件未编译 KV 库，重启后恢复默认值。

## Web 面板

访问 `http://<设备IP>/cfg`，IP 可从串口日志或开机通知获取。

页面由 `/cfg` 与 `/cfg.js` 提供，接口包含 `/api/status`、`/api/config`、`/api/sms`、`/api/test`、`/api/reboot`。
页面提供保存、测试推送、刷新与重启操作，WiFi 卡片为只读。

面板不做鉴权，同一局域网内的任意客户端均可查看短信并修改配置，请勿映射至公网。

## 短信指令

指令发送至设备内的 SIM 卡，且须位于短信正文起始位置：

| 正文 | 效果 |
|---|---|
| `C<tag>REBOOT` | 10 秒后重启设备 |
| `C<tag>SEND手机号 内容` | 以该卡向指定号码发送短信 |

`<tag>` 为配置中的 `tag`（默认 `ziw`）。该口令仅用于防止误触发，知道号码者即可使用本卡发送短信，建议修改默认值。

## 状态灯（GPIO13）

1 = 5 秒一闪（模组无响应）／2 = 常亮（未插卡）／3 = 1 秒一闪（未联网）／4 = 0.2 秒一闪（正常待机）。
GPIO12 为固定心跳灯，用于确认程序运行正常。

## 固件版本

官方 release 为裁剪版本：V1005 / V1006 / V1007 均不含 TLS（推送 Telegram 时报 `NOT SUPPORT TLS`），
也不含 `fskv` / `fdb` 持久化库。本项目使用 V1004（含 TLS，Lua 堆 96KB）。
如需同时具备 TLS 与持久化，须自行编译 `idf5-esp32c3` 并勾选 TLS 组件与 `fdb`。

## 已知限制

- 配置不持久，断电后恢复默认值
- 推送队列上限 50 条，面板历史 12 条 × 240 字节（V1004 的 Lua 堆为 96KB）
- 长短信按「发件人 + sms_id」分组，凑齐后拼接；30 秒未凑齐则发送已收到的部分
- 串口解析在匹配到目标行后即返回，若同一批数据中包含 `+CMT`，该条短信会丢失
- 模组重启后需数秒重新附着，期间无法接收短信

## 面板开发约束

`webcfg.lua` 中的 `PAGE_SHELL` 与 `PAGE_JS` 受以下约束限制：

1. 单次响应上限为 8192 字节（含响应头），超出部分被静默截断。曾因整页截断于 `<script>` 内导致页面空白，故拆分为 `/cfg` 与 `/cfg.js` 两次响应。
2. 页面内不得出现连续两个减号。LuatTools 下载脚本时会将「`--` 至行尾」整段删除（长字符串亦同）。CSS 的 `var(--bg)` 与 JS 的 `i--` 均曾受影响，因此颜色需写死，循环使用 `i = i - 1`。
3. httpsrv 同一时间仅服务 1 个客户端，因此页面不引用任何外部资源（CSS 内嵌）。

## 致谢

- [chenxuuu/sms_forwarding](https://github.com/chenxuuu/sms_forwarding)
- [50 元内自制短信转发器（Air780E + ESP32C3）](https://www.chenxublog.com/2022/10/28/19-9-sms-forwarding-air780e-esp32c3.html)
- [LuatOS](https://gitee.com/openLuat/LuatOS)
