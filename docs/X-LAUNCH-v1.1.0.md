# AgentCurtain v1.1.0：X 发布方案

## 发布目标

让经常用 iPad 远程控制多屏 Mac 的开发者，在几秒内理解 AgentCurtain 解决的具体麻烦：
启用保护后只留下内屏，外屏窗口自动收回；解除保护后，显示器和窗口回到原位。

本轮以项目 GitHub 页为唯一落地页：

<https://github.com/felixlark/agent-curtain>

## 核心叙事

从真实场景切入，不先解释 SPI、event tap 或 watchdog：

> Mac 接了几块外屏，人离开后想用 iPad 远程操作，却要在几个桌面之间来回切。AgentCurtain
> v1.1 启用保护时会暂时断开全部外屏，把窗口收回内屏；解除后再把显示器和窗口恢复。

第二层再讲技术边界：它保持 WindowServer 会话工作、阻断物理键鼠，并提供异常退出恢复；
它不是 macOS 真锁屏，也不应包装成安全产品。

## 首发帖

### 中文

Mac 接了 3 块外屏，用 iPad 远程时却只想看一个桌面。

AgentCurtain v1.1 启用保护后会暂时断开全部外屏，把窗口收回内屏；解除保护后，再按原显示器和原位置恢复。崩溃时，独立 watchdog 也会接管恢复。

开源，适用于 Apple Silicon + macOS 26+：
https://github.com/felixlark/agent-curtain

### English

Three displays on my Mac. On iPad, I want one desktop.

AgentCurtain v1.1 disconnects externals and moves their windows to the built-in screen. Reopen it to restore the layout and window frames—even after a crash.

Open source:
https://github.com/felixlark/agent-curtain

## 配图与演示

首发配一段 12 到 18 秒、无剪切的实机视频，按以下顺序录制：

1. iPad 上的 UU Remote 正显示多个桌面，Mac 外接显示器处于连接状态。
2. 在 Mac 上启用 AgentCurtain，画面切换为单一内屏，窗口已回到内屏。
3. 解除保护，外屏重新连接，选定的三个窗口回到原显示器和原位置。

视频角落同时拍到 Mac 和 iPad，避免把本机录屏误解为远程端效果。不要演示真实密码、
通知内容、个人文件名或远程连接凭据。

如暂时没有实机视频，先使用 `docs/img/banner.png`，并把首发帖中的“iPad”改成
“remote desktop”，等 iPad 画面核验完成后再发视频回复。

## 跟帖节奏

- 首发后第 1 条回复：解释为什么不使用 `pmset displaysleepnow`——它会停止 framebuffer
  合成，GUI agent 和远程桌面也会失去画面。
- 第 2 条回复：说明窗口恢复按显示 UUID 匹配，并覆盖应用被 `kill -9` 的恢复路径。
- 第 3 条回复：明确边界——这是给无人值守 GUI agent 会话使用的“幕帘”，不等同于系统锁屏。
- 24 小时后：如果有人问到兼容性，再补充 BetterDisplay 负责亮度和布局；系统显示 SPI
  负责连接管理，BetterDisplay Pro 只作回退。

## 回复模板

**为什么不用系统锁屏？**

这个工具服务于必须保持 WindowServer 会话工作的 GUI agent 和远程桌面场景。系统锁屏会
改变这条工作链，所以 AgentCurtain 选择调暗显示器、阻断物理输入，并明确显示为“幕帘”。

**能保护电脑安全吗？**

它只用于阻挡路过者的机会型接触，不能替代 FileVault、系统锁屏或物理安全措施。

**为什么还需要 BetterDisplay？**

当前版本仍用 BetterDisplay 的免费能力读取显示器标识、控制亮度并恢复布局。连接管理优先
使用系统 SPI，只有系统 SPI 不可用时才需要 BetterDisplay Pro 回退。

## 发布检查

- GitHub `main`、`v1.1.0` 标签和 Release 指向同一提交。
- README 首屏显示 `v1.1.0`，安装命令可直接复制。
- Release 页面写清外屏断开、窗口恢复、watchdog 和兼容性边界。
- 帖子只使用已经通过安装版验收的能力；iPad 视频发布前必须由实际设备目视确认。
- 首发链接添加 X 自带的点击统计即可，不在项目中加入跟踪代码。
