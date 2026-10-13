# AgentCurtain

**启用保护，后台任务照常运行。**

AgentCurtain 是面向 macOS 26+ 无人值守 GUI agent 会话的菜单栏应用。它把每块
物理显示器调暗，在 HID 事件层阻断物理键鼠，同时让未锁定的 WindowServer 会话
继续合成画面。白名单内的远程桌面进程和 session 层的 agent 注入仍可正常工作。

[English](README.md) · [实测记录](docs/FINDINGS.md) ·
[实现 PRD](docs/PRD-menubar-app.md) ·
[验收矩阵](docs/ACCEPTANCE-menubar-app.md)

**当前版本：[v1.1.0](docs/RELEASE-v1.1.0.md)** · Apple Silicon · macOS 26+

> AgentCurtain 弱于真锁屏。它防的是路过同事、进屋访客等机会型接触，防不住
> 有准备的攻击者、重启、插入新输入设备或物理拆机。“屏幕关闭·输入锁定”表示
> 屏幕亮度归零并启用输入拦截，不等同于 macOS 系统锁屏。

## 交付形态

`/Applications/AgentCurtain.app` 是唯一安装的运行主体，也是唯一需要辅助功能
授权的对象。app 内含：

- 显示保护状态及实时计数的 `NSStatusItem` 菜单；
- 拒绝优先判定、可自愈的 `kCGHIDEventTap` 阻断器；
- 每块显示器一个、可在 framebuffer 中扫描到的提示条；
- 优先用系统显示 SPI 断开/重连外屏，并用 UUID 恢复显示拓扑；
- 以显示 UUID 记录所有屏幕的可见窗口，解除保护后恢复其原显示器和原位置；
- BetterDisplay 用于亮度和布局，Pro 连接管理仅作系统 SPI 不可用时的回退；
- `~/.local/state/curtain/control.sock` 上权限为 0600 的 Unix socket；
- app 被强杀时独立恢复显示拓扑和亮度，再重启 AgentCurtain，由主程序在辅助功能权限下恢复窗口位置的包内看门狗。

`curtain` 是不持有权限的瘦 socket 客户端。它不会创建事件 tap，因此不需要任何
TCC 授权。

## iPad 远程时只留一个屏幕

多屏 Mac 用 iPad 远程控制时很麻烦：远程端要来回切换几个桌面，窗口还散落在不同
屏幕。AgentCurtain v1.1 启用保护后，会把全部外接显示器从活动显示拓扑中断开。
macOS 随即把外屏窗口收回内屏，UU Remote 等远程桌面只需显示和操作一个屏幕。

解除保护后，外屏会重新连接，仍然存在的窗口按原显示器和原位置恢复。恢复过程用显示
UUID 识别设备，即使系统重新分配了临时 Display ID 也能对应；主程序意外退出时，包内
看门狗也会执行同一套恢复流程。

## 安装

依赖：

- Apple Silicon、macOS 26 或以上；
- Xcode Command Line Tools；
- 已安装带 `betterdisplaycli` 的 BetterDisplay；Pro 为可选回退；
- 从源码构建时，钥匙串内有 PRD 指定的 Developer ID 身份。

```bash
git clone https://github.com/longbiaochen/agent-curtain.git
cd agent-curtain
./install.sh
```

主程序、包内恢复看门狗、外层 app 都使用以下身份签名：

```text
Developer ID Application: LONGBIAO CHEN (HJG65XBC25)
```

构建强制启用 Hardened Runtime 和安全时间戳；找不到身份时直接失败，不回退到
ad-hoc 签名。安装后还会对 `/Applications` 中的 app 再做一次严格验证。

第一次启用前，到“系统设置 → 隐私与安全性 → 辅助功能”勾选 **AgentCurtain**。
它的 designated requirement 基于 bundle identifier、Apple anchor 和 Team ID，
不含 `cdhash`，因此后续用同一身份重编译、升级不需要重新授权。

## 使用

可以用菜单栏图标、全局快捷键或兼容 CLI：

```bash
curtain on
curtain status
curtain off
curtain allow
curtain deny
curtain doctor
```

旧有的定时形式继续支持：

```bash
curtain on 3600
curtain on --allow-any-injected
```

拒绝名单为空时，`--allow-any-injected` 会被拒绝。全局快捷键：

- `Ctrl+Opt+Cmd+L`：启用保护；
- `Ctrl+Opt+Cmd+U`：解除保护，也可取消正在进行的启用操作。

提示条与各屏菜单栏等高、居中显示；刘海屏将状态和快捷键放在刘海两侧，左右对称。
操作开始立即显示浅色“启用中”或“解除中”。启用完成才变为深红“屏幕关闭·输入锁定”；解除
完成后短暂显示“已解除”并淡出。窗口在状态切换时保持原位。

解除热键在 HID 回调吞掉按键前检查。`curtain off` 只与 app 的 socket 通信，
包括从 SSH 执行时也不需要辅助功能权限。

## 配置

- `~/.config/curtain/allowlist`：允许的可执行文件路径，一行一个；
- `~/.config/curtain/denylist`：永远拦截，优先级最高。

空行和以 `#` 开头的行会忽略。`.app` 规则解析到精确的 bundle executable；
非路径规则只匹配完整进程名。PID 解析使用 `proc_listallpids` + `proc_pidpath`，
绝不使用 `pgrep -f` 子串匹配，并且每 3 秒刷新一次。

默认拒绝名单包含 PRD 要求的三个 Karabiner 组件。

## 运行安全

启用保护的顺序可回滚：

1. 先确认 AgentCurtain 自己已有辅助功能授权，并显示浅色“启用中”；
2. 按显示 UUID 记录显示拓扑及所有屏幕当前可见窗口的原位置；
3. 按 `displayID` 读取所有活动显示器原亮度，并原子写入权限 0600 的恢复记录；
4. 启动包内独立恢复看门狗；
5. 逐屏在一次 BetterDisplay 调用中设置亮度为 0 并读回；
6. 挂上 HID event tap，把内屏设为临时主屏，并优先通过一次系统 SPI 事务断开所有外屏；
7. 核对仅剩内屏后，提示条变为深红“屏幕关闭·输入锁定”。

任何一步失败都会重连外屏并回滚显示拓扑和亮度。正常 `off`、从菜单退出、`SIGTERM`、
定时解除和解除热键都会先恢复原来的主屏、排列、分辨率和旋转，再恢复亮度和窗口位置。
`kill -9` 无法执行 app 清理，因此独立看门狗会观察主进程退出，使用权限 0600 的恢复记录
恢复显示拓扑和亮度，再重启 AgentCurtain，由持有辅助功能权限的主程序回放窗口；后续启动仍会
重试孤立的恢复记录。窗口回放会等待显示器 bounds 稳定，优先按 CGWindowID、AXIdentifier、
标题和稳定窗口顺序做一对一匹配，再使用 `size → position → size` 写入并读回验证；不会激活或
抬升应用。全屏、最小化、其他 Space 中不可见及保护期间新增的窗口不会被移动。

显示器变化通知会重建提示条，并把新插入显示器的 UUID、拓扑及原亮度追加到恢复记录，
随后调暗并断开新外屏，使保护期间始终只保留内屏。

AgentCurtain 绝不调用 `pmset displaysleepnow`，因为 display sleep 会停止
framebuffer 合成，让 GUI agent 失明。

显示连接优先使用运行时解析的私有 `CGSConfigureDisplayEnabled`，BetterDisplay Pro
只在该符号不可用时回退。私有 SPI 可能随 macOS 更新变化，升级系统后应重新执行硬件验收。

## 开发与验证

```bash
./script/build_and_run.sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --install
```

Codex 的 Run 按钮也指向同一脚本。`--verify` 会运行 Swift 测试、严格验证签名、
启动已签名 bundle、检查 socket 权限为 0600，并验证 JSON `status` 响应。

保护启用后，用下列命令逐块验证 framebuffer 中真的画出了提示条：

```bash
./script/verify_banner_framebuffer.sh
```

它按 `CGDirectDisplayID` 扫描实际渲染的特征色；仅仅看到提示条进程或 `NSWindow`
仍存活不算通过。

硬件验收必须单独进行。尤其是“物理键鼠确实无效”只能由真人按键/移动鼠标验证：
应看到 `blocked` 上升且界面无响应。程序化注入到不了同一 HID 路径，不能替代这项
证据。完整逐项清单见
[docs/PRD-menubar-app.md](docs/PRD-menubar-app.md#9-验收标准)。

亮度恢复：解除保护（包括崩溃恢复）后，按 UUID 恢复每块屏幕在启用保护前保存的亮度。
