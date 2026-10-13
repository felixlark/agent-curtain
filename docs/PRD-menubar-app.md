# PRD:AgentCurtain 菜单栏应用

**目标读者:** 实现者(Codex)
**状态:** 已实现至 v1.1.3；实机验收推进中，见
[当前验收矩阵](ACCEPTANCE-menubar-app.md)与[下一里程碑](PLAN-post-v1.1.3.md)。
**前置:** 本仓库现有的 zsh + ad-hoc Swift 原型已验证核心机制可行,见
[FINDINGS.md](FINDINGS.md)。本 PRD 是把原型重构为正式 app。

---

## 1. 背景

`agent-curtain` 是 macOS 上的「假锁屏」:熄灭全部显示器、阻断物理键鼠,
但保持登录会话解锁,让 GUI agent 继续工作,同时放行白名单内的远程桌面工具。

现有原型由三部分拼成:

```
~/.local/bin/curtain              zsh 脚本(CLI + 编排)
~/.local/libexec/hid-blocker      Swift,ad-hoc 签名,事件阻断
~/.local/libexec/curtain-banner   Swift,ad-hoc 签名,提示条
```

核心机制已用实测验证(见 §6),但工程形态有三个硬伤,这正是本次重构的动因。

## 2. 要解决的问题

### 2.1 ad-hoc 签名导致授权反复失效(最痛)

`hid-blocker` 用 `swiftc` 直接编译,得到 **ad-hoc 签名**,其 designated
requirement 包含 **cdhash**。TCC 授权绑定 requirement,因此**每次重新编译,
辅助功能授权立即作废**。开发期间这个问题反复出现:授权 → 改代码 → 重编译 →
授权失效 → 再授权,且失效时的报错与"从未授权"完全相同,极易误判。

对照:Developer ID 签名的 app,其 requirement 形如

```
identifier "com.example.app" and anchor apple generic
  and certificate leaf[subject.OU] = TEAMID
```

**不含 cdhash**,因此重新编译、版本升级都不影响已有授权。

### 2.2 授权对象分散

当前需要给三个不同主体授权才能完整工作:`hid-blocker`(创建事件 tap)、
调用方终端(TCC 按责任进程归责)、以及截图所需的屏幕录制权限持有者。
每换一个启动路径就要重新配一遍。

### 2.3 无 GUI,状态不可见

只能靠 `curtain status` 查文本。用户希望在菜单栏直接看到状态并一键切换。

## 3. 目标

交付**单个** `AgentCurtain.app`:

- 用 **Developer ID Application: LONGBIAO CHEN (HJG65XBC25)** 签名
- 菜单栏图标显示状态,点击切换
- 内嵌事件阻断、提示条、亮度控制
- 暴露本地控制端点,供瘦 CLI 远程驱动
- **只需授权它一个**,且授权在后续重编译/升级后依然有效

### 非目标

- 不做公证(notarization)。仅自用,Developer ID 签名足够。
- 不替代真锁屏。安全模型见 §7。
- 不支持 Intel Mac / macOS 26 以下(未验证,不承诺)。

## 4. 架构

```
AgentCurtain.app                       Developer ID 签名,授权唯一对象
├─ MenuBarController                   NSStatusItem,状态显示与切换
├─ InputBlocker                        CGEventTap @ kCGHIDEventTap
├─ BannerController                    NSWindow,每屏一个
├─ BrightnessController                betterdisplaycli 封装
├─ ControlServer                       Unix domain socket
└─ Config                              allowlist / denylist

curtain(瘦 CLI,可为 shell 脚本)      不需要任何 TCC 权限
└─ 向 socket 写一行命令
```

### 4.1 控制端点

Unix domain socket,路径 `~/.local/state/curtain/control.sock`,权限 **0600**。

选它而非 URL scheme 或本地 HTTP 的理由:文件权限即访问控制、无网络暴露、
CLI 实现极简。干活的是已授权的 app,**CLI 自身不需要任何权限** —— 这解决了
原型里"ssh 远程启用需要给阻断器常驻辅助功能授权,权限过大"的顾虑。

协议:一行文本命令,一行 JSON 响应。

```
→ on
← {"ok":true,"state":"drawn","displays":4,"allowed":1,"denied":3}
→ off
← {"ok":true,"state":"open"}
→ status
← {"ok":true,"state":"drawn","blocked":12,"allowed":340,"since":"..."}
```

## 5. 详细需求

### 5.1 菜单栏

- 图标反映状态:幕帘拉上 / 拉开(建议用 SF Symbols,如
  `curtain.closed` 无对应符号时用 `eye.slash` / `eye`)
- 点击菜单包含:拉上幕帘 / 拉开幕帘、状态摘要(阻断计数、放行计数)、
  编辑白名单、编辑拒绝名单、退出
- **app 必须是 accessory(`LSUIElement`),不进 Dock、不抢焦点**

### 5.2 输入阻断

在 `kCGHIDEventTap` 创建 `.defaultTap`,掩码覆盖:
`keyDown/keyUp/flagsChanged`、`leftMouseDown/Up`、`rightMouseDown/Up`、
`otherMouseDown/Up`、`leftMouseDragged/rightMouseDragged`、
`scrollWheel`、`mouseMoved`。

判定顺序(**拒绝优先**):

```
pid = event.getIntegerValueField(.eventSourceUnixProcessID)
if pid != 0 && deniedPIDs.contains(pid)  → 拦截
if pid != 0 && (allowAnyInjected || allowedPIDs.contains(pid)) → 放行
否则 → 拦截
```

必须处理 `.tapDisabledByTimeout` / `.tapDisabledByUserInput`,收到后立即
`CGEvent.tapEnable(enable: true)` 自愈。

PID 解析:用 `proc_listallpids` + `proc_pidpath` 精确匹配可执行路径,
**不要用 `pgrep -f`** —— 子串匹配会误伤(原型中连配置文件的注释行都能
"匹配到 3 个进程")。每 3 秒刷新一次,使进程重启换 PID 后依然有效。

### 5.3 提示条

每个 `NSScreen` 一个无边框窗口,顶部居中,`level = .screenSaver`,
`ignoresMouseEvents = true`,`collectionBehavior` 含 `.canJoinAllSpaces`
和 `.stationary`。监听 `didChangeScreenParametersNotification`,
显示器插拔时重建。

文案可本地化,默认英文,允许覆盖。

**验收要点:** 提示条"进程在跑"不等于"窗口画出来了"。原型中曾出现
`status` 报显示中、但四块屏扫描不到横幅的假阳性。必须以扫描 framebuffer
特征色为准。

### 5.4 亮度控制

调用 `betterdisplaycli`。两个必须遵守的约束:

- **必须用 `-displayID` 定址。** `name` 在同型号显示器上会冲突
  (两块小米都叫 `Mi Monitor`);`originalName` 匹配不上内置显示器
  (它是 `Color LCD`,但 `-namelike="Color LCD"` 返回空)。
- **绝不使用 `pmset displaysleepnow`。** 它会让窗口服务器停止合成,
  GUI agent 随之失明(实测截图变 `0.0/255`,部分显示器直接失败)。

拉上前记录每块屏的原亮度,拉开时逐块恢复。

**恢复必须是无条件的:** 无论 app 崩溃、被强杀还是正常退出,亮度都要恢复。
原型用外部看门狗实现;app 内可用 `NSApplication` 终止通知 + 信号处理,
但建议保留一个独立的恢复兜底(如崩溃后下次启动时检测残留状态文件并恢复)。

### 5.5 配置

```
~/.config/curtain/allowlist    放行的可执行文件路径,一行一个,# 注释
~/.config/curtain/denylist     永远拦截,优先级最高
```

denylist 默认内容必须包含 Karabiner 的三个组件(见 §6.3)。

## 6. 技术要点(全部来自实测,勿凭直觉改动)

完整数据见 [FINDINGS.md](FINDINGS.md)。以下是实现时最容易踩错的几条。

### 6.1 事件分层是整个设计的基础

物理输入进入 `kCGHIDEventTap`;agent 用
`CGEvent.post(tap: .cgSessionEventTap)` 注入的事件**不经过该层**。

| 注入目标 | HID 层观察到 | session 层观察到 |
|---|---|---|
| `.cgSessionEventTap` | 0 | 1 |
| `.cghidEventTap` | 1 | 1 |

因此挂在 HID 层的阻断器天然不影响 agent。**不要把 tap 挂到 session 层**,
那会把 agent 一起挡掉。

### 6.2 远程桌面按 PID 放行

远程桌面工具在软件层注入但仍经过 HID 层,事件带注入进程 PID;
真实硬件事件该值为 `0`。实测 679/679 事件归属明确。

### 6.3 拒绝名单:为无法测量的量做设计

键盘增强工具(Karabiner-Elements)抓取物理键盘后经自身虚拟 HID 设备重发事件。
若重发事件带非零 PID,"放行一切 `pid != 0`"会把物理键盘整体放行。

**不要去验证究竟是哪种**,直接用拒绝名单让两种可能都安全:带 PID 则拦下,
是 `pid=0` 则是无害空操作。

默认拒绝名单(注意 dext 路径含随机 UUID,应按进程名而非路径匹配):

```
/Library/Application Support/org.pqrs/Karabiner-Elements/Karabiner-Core-Service.app
/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app
org.pqrs.Karabiner-DriverKit-VirtualHIDDevice
```

### 6.4 TCC 归责

创建事件 tap 需辅助功能权限,macOS 按**责任进程**归责而非按二进制:

| 启动路径 | 责任进程 | 能否创建 tap |
|---|---|---|
| 已授权的交互式 shell | 该 shell | ✅ |
| SSH 直接 fork | `sshd` | ❌ |
| launchd | 二进制自身(需其自有授权) | ✅ |
| AppleScript applet | applet 自身 | ❌ |

**app 化后这一段大部分消失** —— app 自己就是责任进程,授权给它即可。
这正是本次重构的核心收益。

### 6.5 解除路径必须不需要权限

`off` 只需发信号 + 恢复亮度,**不得**要求任何 TCC 权限。这是"永远不会把
自己锁在外面"的保证。CLI 走 socket,socket 由已授权的 app 持有,
因此 CLI 天然无需权限。

## 7. 安全模型(必须在 UI 与文档中如实呈现)

本工具**弱于真锁屏**。会话保持解锁,任何能绕过输入阻断的人——插新键盘、
重启、拆硬盘——都能到达桌面。它防的是**机会型接触**(路过的同事、进屋的访客),
防不住有准备的攻击者。

不要在 UI 上把它表述为"锁定"或"安全"。建议措辞:"幕帘已拉上 · 物理键鼠已阻断"。

## 8. 签名与分发

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: LONGBIAO CHEN (HJG65XBC25)" \
  AgentCurtain.app
```

验证 requirement **不含 cdhash**:

```bash
codesign -d -r- AgentCurtain.app
# 期望形如:
# designated => identifier "..." and anchor apple generic
#   and certificate leaf[subject.OU] = HJG65XBC25
```

若输出里出现 `cdhash`,说明签名方式不对,授权仍会在重编译后失效 —— 这是
本次重构必须达成的核心指标。

安装到 `/Applications/AgentCurtain.app`。不做公证。

## 9. 验收标准

| # | 项目 | 判定方式 |
|---|---|---|
| 1 | 授权一次后重编译仍有效 | 授权 → 改代码重新签名构建 → 无需重新授权即可拉上幕帘 |
| 2 | requirement 不含 cdhash | `codesign -d -r-` 输出人工检查 |
| 3 | 四块屏全部熄灭 | 逐块 `betterdisplaycli get -displayID=N -brightness` 均为 0 |
| 4 | 截图仍拿到真实内容 | `screencapture` 平均亮度与基线相当,**不是** 0 |
| 5 | 提示条真的画出来了 | 扫描各屏 framebuffer 特征色,**不接受**"进程在跑"作为证据 |
| 6 | **物理键鼠确实无效** | **真人按键**,观察 `blocked` 计数上升且无响应 |
| 7 | 白名单放行远程桌面 | 远程桌面操作正常,`allowed` 计数上升 |
| 8 | 拒绝名单优先级最高 | 把某白名单进程同时加入拒绝名单,应被拦截 |
| 9 | 解除不需要权限 | 从未授权的 shell(如 ssh)执行 `curtain off` 成功 |
| 10 | 崩溃后亮度恢复 | `kill -9` app,亮度应恢复 |
| 11 | 显示器插拔 | 拔掉一块再插回,提示条应重建 |

**第 6 项是唯一无法自动化的** —— 程序化合成的键盘事件到不了 HID 层,
必须真人按键。原型阶段这一项始终未验证,是当前最大的未决风险。

## 10. 迁移

保留 `curtain` 命令名与 `on/off/status/allow/deny` 子命令,使现有习惯和
Karabiner 热键配置无需改动。原型的三个文件在 app 可用后删除。

热键建议由 app 自己注册全局快捷键(`Ctrl+Opt+Cmd+Shift+L/U`),
不再依赖 Karabiner —— 但需注意:**阻断生效时 app 自己的事件 tap 会先看到
按键**,应在吞掉之前检查解除热键。
