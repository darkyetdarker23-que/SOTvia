# ChatGPT via SOT 1.0.0

这是一个面向 Windows 的启动与诊断工具，用独立的 SOT `x_tunnel` 实例为 ChatGPT 桌面端提供代理，并为桌面端的 durable WebSocket 增加本地 TCP 转发。

本包**不包含 SOT、ChatGPT、任何 SOT 账号、ChatGPT 登录态或作者电脑上的配置文件**。每位使用者必须使用自己的 SOT 安装与账号。

## 使用条件

- Windows 10/11，系统自带 Windows PowerShell 5.1。
- 已安装并能正常使用 SOT；本包以 SOT 1.2.1 为测试基准。
- 已安装 Microsoft Store 版 OpenAI.Codex/ChatGPT 桌面端；本包以 `26.1013.4894.0` 为测试基准。
- 安装时可以确认一次 Windows UAC，用于备份和修改 `hosts`。
- 本机端口 `127.0.0.1:443`、`127.0.0.1:1081` 和控制端口 `8285` 没有被其他程序占用。

ChatGPT 或 SOT 更新后，其内部路径或网络行为可能改变。安装器和诊断器会做若干兼容性检查，但无法替代对新版本的实测。

## 安装

1. 安装并启动 SOT，在 SOT 中完成登录，确认它本身能正常打开网页。
2. 安装 Microsoft Store 版 ChatGPT 桌面端，并至少正常启动过一次。
3. 解压整个目录，不要只单独复制 `Install.cmd`。
4. 双击 `Install.cmd`。
5. 出现 Windows UAC 时确认“是”。安装器只在这一步修改 `hosts`，并会先创建备份。

程序会安装到：

```text
%LOCALAPPDATA%\ChatGPT-via-SOT
```

独立隧道数据会在首次启动时创建于：

```text
%APPDATA%\sot-chatgpt-tunnel
```

`hosts` 备份会保留在：

```text
%LOCALAPPDATA%\ChatGPT-via-SOT-hosts-backups
```

安装器会创建桌面快捷方式，以及开始菜单中的启动、浏览器、停止、诊断和卸载入口。

## 每次开机后的正确使用顺序

1. 先启动 SOT，等待其完成登录并确认网页可用。
2. 双击桌面的 **ChatGPT via SOT**。
3. 等窗口显示隧道、转发器和 ChatGPT 启动结果。
4. 出现“按回车关闭启动窗口”后可以放心关闭窗口或按回车；代理进程和 ChatGPT 都是独立进程，不会随窗口退出。
5. 使用结束后，运行桌面的 **停止 ChatGPT via SOT**；该快捷方式会同时关闭 ChatGPT、本工具的转发器和独立隧道。

不要直接从开始菜单或任务栏启动普通 ChatGPT；那样新进程不会继承本工具设置的环境变量和 Chromium 代理参数。

## 工作原理

本工具在当前用户下启动一套独立 SOT 隧道：

```text
ChatGPT Chromium / HTTP 请求
        -> 127.0.0.1:1081
        -> SOT x_tunnel

ChatGPT durable WebSocket
        -> hosts: codex-cloud-backend.chatgpt.com = 127.0.0.1
        -> 127.0.0.1:443 本地 TCP 转发器
        -> SOCKS5 127.0.0.1:1081
        -> 真实服务器（远端 DNS，TLS 原样透传）
```

转发器不解密 TLS、不安装证书，也不保存 ChatGPT 内容。它只在字节层转发 TCP。

代理停止后 `hosts` 映射仍会保留。此时该 durable 主机通常会快速得到本机“连接被拒绝”，不会自动绕过工具直连公网；下次通过专用快捷方式启动时，转发器会重新上线。

## 诊断

运行 `Diagnose.cmd`，或从开始菜单运行 **诊断 ChatGPT via SOT**。诊断会检查：

- SOT 程序与当前用户登录配置是否存在；
- ChatGPT 版本及 `app.asar` 中是否仍包含预期 durable 主机；
- `hosts` 是否只把 durable 主机解析到本机；
- 443、1081、8285 的监听进程是否属于本工具；
- 隧道出口公网 IP（隧道在线时）；
- ChatGPT 是否出现非 loopback 的外网直连 TCP；
- 最近日志是否包含 durable `connected`。

诊断不会显示或上传 SOT 登录账号。公网 IP 检查会经隧道访问 `api.ipify.org`；检查失败不会自动改变配置。

常见错误：

- **SOT 本体未运行**：先启动 SOT 并确认登录成功。
- **端口被占用**：运行诊断查看占用者。工具不会强行结束无法确认归属的进程。
- **hosts 不正确**：重新运行 `Install.cmd` 并确认 UAC；如果存在其他软件管理的冲突行，安装器会停止而不会覆盖。
- **更新后兼容性检查失败**：停止使用，等待针对新版 ChatGPT/SOT 的工具更新，不要绕过检查。

## 卸载

从开始菜单运行 **卸载 ChatGPT via SOT**，或在安装目录运行 `Uninstall.cmd`。

卸载器会：

- 关闭 ChatGPT 和本工具确认归属的隧道/转发器；
- 经 UAC 删除本工具带标记的 `hosts` 区块；
- 删除快捷方式、独立隧道数据、浏览器独立配置和程序目录；
- 保留 SOT 本体、SOT 原始用户数据、ChatGPT，以及 LocalAppData 下的 hosts 备份。

如果安装时发现 `hosts` 已有相同映射，安装器会复用它但不取得所有权，卸载时也不会删除该外部映射。

## 分发者检查清单

分发时发送完整 ZIP，不要额外加入以下内容：

- `%APPDATA%\sot` 或任何 `client.json`；
- `%APPDATA%\sot-chatgpt-tunnel`；
- `%LOCALAPPDATA%\Codex`、浏览器用户目录或 Cookie；
- `config.json`（它应由每台电脑的安装器本地生成）；
- SOT 或 ChatGPT 程序文件，除非你另行确认了软件授权。

发布前核对 ZIP 的 SHA-256，并让接收者从可信渠道取得 ZIP 与哈希值。

## 文件说明

- `Install.cmd` / `Install.ps1`：探测依赖、兼容性检查、配置 hosts 与创建快捷方式。
- `Start-ChatGPT-via-SOT.ps1`：同步本机 SOT 配置、启动独立隧道与转发器、启动 ChatGPT 并验证连接。
- `Stop-ChatGPT-via-SOT.ps1`：仅停止能验证为本工具启动的进程。
- `Start-Browser-via-SOT.ps1`：通过相同隧道打开独立的 Chrome/Edge 用户目录。
- `Diagnose.cmd` / `Diagnose.ps1`：只读诊断（公网 IP 探测除外）。
- `Uninstall.cmd` / `Uninstall.ps1`：安全卸载。
- `Manage-Hosts.ps1`：仅由安装/卸载流程以管理员权限调用。
- `ws-cloud-forwarder.py`：durable TCP 到 SOCKS5 的 TLS 透传转发器。
- `SHA256SUMS.txt`：包内文件校验值；ZIP 本身的哈希另附在同目录。

## 安全边界

这是基于特定 SOT 与 ChatGPT 版本行为制作的兼容工具，不是通用 VPN，也不保证所有 UDP、系统服务或其他应用都走代理。脚本会报告它能观察到的 ChatGPT TCP 直连，但操作系统、应用更新及外部网络条件仍可能改变结果。涉及敏感账号时，应由接收者自行审查脚本并在可控环境中验证。
