# 实测记录

全部数据来自 MacBookPro18,4 / macOS 26.5.2 / 2026-09-01,四显示器
(内置 Liquid Retina XDR + 小米 ×2 + DELL U3219Q)。

## 0. 评估结论与证据等级

在“会话必须保持解锁，GUI agent 必须继续操作”的约束下，本方案是可行的工程性
幕帘，而不是真锁屏替代品。它适用于阻挡路过者的机会型访问；不适用于对抗会重启、
换接输入设备、拆机或主动攻击本机的人。

| 结论 | 证据等级 | 当前状态 |
|---|---|---|
| HID tap 不接收 session 层注入 | 本机对照实测 + Apple API 分层定义 | 已验证 |
| UURemote 事件可按源 PID 放行 | 本机 679 个事件采样 | 已验证 |
| 四屏亮度归零仍保留 framebuffer | 四屏读回 + 截图对照 | 已验证 |
| SSH 可启动/解除，退出后仍有看门狗 | launchd 安装版往返 | 需在本次修复后重验 |
| 真实键盘、触控板/鼠标被阻断 | 必须现场真人输入 | **未验证** |
| 解除热键可用 | 必须现场真人输入 | **未验证** |

Apple 官方定义 `cghidEventTap` 位于 HID 事件进入 WindowServer 的位置，并提供
`eventSourceUnixProcessID` 字段读取事件源 PID：
[CGEventTapLocation.cghidEventTap](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation/cghideventtap)、
[CGEventField.eventSourceUnixProcessID](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventsourceunixprocessid)。
这些 API 定义支持实现边界，但“本机具体工具的事件路径”仍以本机对照实测为准。

## 1. 事件分层:为什么 HID 层阻断不影响 agent

在 `kCGHIDEventTap` 和 `kCGSessionEventTap` 各挂一个 listen-only tap,
分别向两层注入合成事件:

| 注入目标 | HID tap 观察到 | Session tap 观察到 |
|---|---|---|
| `.cgSessionEventTap` | 0 | 1 |
| `.cghidEventTap` | 1 | 1 |

**Session 层注入的事件不经过 HID 层。** agent 用
`CGEvent.post(tap:.cgSessionEventTap)`,因此挂在 HID 层的阻断器看不见它、
也就挡不住它。

阻断状态下的对照(同样两次注入):

| | HID tap | Session tap |
|---|---|---|
| 基线 | 1 | **2** |
| 阻断中 | 1 | **1** |

阻断中 Session tap 只收到 1 个 —— 少的那个正是 HID 层注入的,被吞掉了。

## 2. 远程桌面工具可按 PID 精确放行

远程桌面(实测对象 UURemote)是软件注入且经过 HID 层,事件带发起进程 PID:

```
RESULT total=679
  pid=58218  n=679  /Applications/UURemote.app/Contents/Helpers/UURemoteServer
```

679/679 全部归属明确,故可在回调里读
`CGEventField.eventSourceUnixProcessID` 精确放行。真实硬件事件的 PID 为 0。

白名单生效后的真实使用统计:

```
RELEASED (SIGTERM) blocked=0 allowed=1936
```

## 3. 调光不影响画面捕获;display sleep 会

| 手段 | 物理面板 | `screencapture` 结果 |
|---|---|---|
| 基线(不处理) | 亮 | 241.2 / 255 |
| DDC/BetterDisplay 亮度归零 | 黑 | **222.6 / 255**(真实内容) |
| `pmset displaysleepnow` | 黑 | **0.0 / 255**,部分显示器直接截图失败 |

**`pmset displaysleepnow` 绝不可用于此目的** —— 它让 WindowServer 停止合成,
GUI agent 随之失明。

## 4. 显示器控制:m1ddc 不够,且必须用 displayID 定址

`m1ddc` 对内置屏和 DELL U3219Q 写不进去:

```
display 1: 110 → 写 0 → 110   ✗
display 4: 110 → 写 0 → 110   ✗
```

改用 BetterDisplay 后四块全部成功。但**必须用 `-displayID` 定址**:

| 字段 | 问题 |
|---|---|
| `name` | 两块小米都叫 `Mi Monitor`,一次匹配两块 |
| `originalName` | 内置屏是 `Color LCD`,但 `-namelike="Color LCD"` 返回空 |
| `displayID` | ✅ 唯一且稳定 |

## 5. TCC 归责:哪些启动路径能创建事件 tap

创建事件 tap 需要辅助功能权限,而 TCC 按**责任进程**归责:

| 启动方式 | 责任进程 | `curtain on` |
|---|---|---|
| 已授权的交互式 shell | 该 shell | ✅ |
| SSH 直接 fork | `sshd` | ❌ |
| **SSH → `launchctl submit`** | **二进制自身** | **✅** |
| AppleScript applet | applet 自身 | ❌ |

关键点:**给 `hid-blocker` 自己授权还不够** —— 从 ssh 会话直接 fork 时,
责任进程是 `sshd`,会压过二进制自身的授权。必须交给 launchd 启动,
归责才回到二进制本身。

实测对比(授权已就位的前提下):

```
ssh → 直接启动           FAIL: 缺少辅助功能授权
ssh → launchctl submit   ARMED ✅
```

`launchctl asuser` 不行:非 root 时报
`Could not switch to audit session: Operation not permitted`;
加 `sudo -u` 后归责链又变,仍然失败。

**2026-09-01 起改为直接 fork,不再用 `launchctl submit`**(commit `c63e631`)。
理由是安全:走 launchd 要求给一个能吞掉全部物理输入的二进制常驻授权,
而且任何能 ssh 进来的人都能启用它。直接 fork 把归责交回调用方,
只有已授权的交互式终端能 `on`。代价见下面第 9 节 —— **`on` 的成败从此
取决于调用方进程链此刻的授权状态**,而那不是一个稳定的东西。

授权给 `hid-blocker` 自身这条路还有一个坑:系统设置里按路径添加的条目,
`csreq` 钉的是 **cdhash**(实测 `cdhash H"02e7…"`),不是 Developer ID
的 identifier+anchor。所以二进制内容一变条目就失配,而且**取消勾选再勾上
不会刷新 csreq** —— 必须「−」删掉整条再「+」加回。失配时系统设置里
看起来仍然是勾着的,极易误判。`curtain doctor` 现在会把新旧 cdhash 并排打出来。

**但 `curtain off` 不需要任何权限** —— 它只是发 SIGTERM 加恢复亮度,
任何终端、任何会话都能执行。这是"永远不会被锁在外面"的保证。

## 6. 为什么不用真锁屏

- **Codex Locked use** 在本机日志中存在插件冷启动竞态:锁屏后 SecurityAgentHelper 加载
  插件需时间,而 Computer Use 的提交后验证窗口约 2 秒,插件晚约 0.34 秒
  创建完 → 收到 `DENY`;重试又与前一条授权链重叠。当前 OpenAI Docs 未找到
  对锁屏运行的公开可用性保证，因此这里保留为本机实测结论，不外推到所有版本。
- **Claude Computer Use** 当前官方限制要求桌面保持 active/awake 且 Claude Desktop
  保持打开，见
  [Anthropic Computer Use 当前限制](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork#current-limitations)。

排查过程中另有两个易误判之处记录在此:

- `Library Validation failed ... StagedPlugins/...` 是**回落噪音**,不是故障。
  系统试完暂存路径失败后会从标准路径成功加载,
  `authd: running mechanism CodexComputerUseAuthorizationPlugin:allow` 即证据。
- `sysadminctl -screenLock status` 报 `off` **不代表不会锁屏**。
  `askForPassword=1` 加上启动屏保仍会真正锁上。这两个开关不是同一套机制。

## 7. 拒绝名单:如何在不确定性下做安全设计

「放行一切 `pid != 0`」可免去白名单配置,但存在一个无法远程验证的风险:
键盘增强工具抓取物理键盘后经虚拟 HID 设备重发事件,若带非零 PID 则物理输入
被整体放行。

本项目未去验证「Karabiner 重发事件是否带 PID」,而是用**拒绝名单**让两种
可能都安全:

| 若重发事件 | 拒绝名单的作用 |
|---|---|
| 带非零 PID | 堵住它,物理输入仍被拦 |
| 为 `pid=0` | 无害的空操作,本来就会被拦 |

本机解析结果(Karabiner-Elements 14.x):

```
[3 个进程] Karabiner-Core-Service.app
[2 个进程] Karabiner-VirtualHIDDevice-Daemon.app
[3 个进程] org.pqrs.Karabiner-DriverKit-VirtualHIDDevice
```

注意 dext 位于 `/Library/SystemExtensions/<UUID>/`,UUID 因机器而异，故按
`proc_pidpath` 结果的可执行文件 basename 精确匹配；普通 allow/deny 路径则按
规范化后的完整可执行文件路径匹配。`.app` 规则先通过 Bundle 元数据解析到其
`CFBundleExecutable`，不使用可被参数文本伪造的 `pgrep -f` 包含匹配。

## 8. launchd 生命周期修复

早期版本仅用 `launchctl submit` 托管阻断器；提示条和亮度看门狗仍是发起 shell 的
后台子进程。安装版核验发现阻断器存活时提示条 PID 已失效，且状态无法证明看门狗
独立于 SSH shell。

当时修复采用以下三个 job；公开文稿以 `<app-namespace>` 代替私有命名空间，实际标识保留在受控原件：

- `<app-namespace>.curtain-blocker`：TCC 责任进程稳定的 HID 阻断器；
- `<app-namespace>.curtain-banner`：GUI session 内持久的远程提示条；
- `<app-namespace>.curtain-watchdog`：监控精确 blocker PID，退出后原子认领亮度备份并恢复。

`curtain on` 只有在四屏调暗读回、阻断器和看门狗都成功后才报告生效；调光失败、
阻断器失败或看门狗失败会回滚。`curtain off` 不依赖 TCC，并保留旧版本状态的恢复
兼容路径。

## 9. 事故复盘:2026-09-02,幕帘掉了近一小时没人知道

### 现象

`curtain on` 报 `FAIL: 缺少辅助功能授权`。同一时刻,那个会话的屏幕录制、
文稿文件夹、完全磁盘访问也全部失效。机器主人在外地,四块屏亮着、会话解锁。

### 一次错误的归因

第一反应是"用户在系统设置里把授权重置了"—— `TCC.db` 的 mtime 恰好落在
前一晚在系统设置里操作的时间。**这个结论是错的。** 查 `TCC.db` 发现授权
一条都没少:

| 条目 | auth | last_modified |
|---|---|---|
| `com.anthropic.claude-code` ScreenCapture | 2 | 2026-08-06 |
| `com.anthropic.claude-code` SystemPolicyAllFiles | 2 | 2026-08-31 |

这两行当天根本没被改过,但当时 `screencapture` 和读 `TCC.db` 都失败。
**授权在,是校验没过。**

误判的直接原因是诊断时用了 `2>/dev/null`:`sqlite3` 的
`authorization denied` 被吞掉,空结果被当成"表被清空了"。
查权限问题时不要吞 stderr。

### 真正的原因

那个 agent 会话的 TCC 责任 bundle 是版本化的 helper:

```
~/Library/Application Support/Claude/claude-code/2.1.247/claude.app
```

当天 09:33 客户端自动升级到 2.1.255,**把 2.1.247 整个目录删了**
(该目录 mtime 与升级时刻吻合,升级后只剩当前版本)。正在运行的会话
责任 bundle 路径悬空 → 校验失败 → 四项 TCC 能力**同时**失效。
新开的会话不受影响。上游 issue: `anthropics/claude-code#50735`。

这解释了为什么 `curtain on` 从 Terminal.app 走一直是好的
(同日 09:33:51 的 tccd 日志里,责任=Terminal 的 hid-blocker 拿到了
`kTCCServicePostEvent = 2`,tap 建起来了),从 agent 会话走却挂了。

### 三个把小故障放大的设计问题

1. **`doctor` 全绿但 `on` 会失败。** 它查依赖、名单、显示器、签名,
   唯独不查"当前调用链有没有辅助功能授权"—— 而这是唯一会挂的东西。
2. **`curtain on` 用 `: > $LOG` 截断日志**,把上一轮怎么结束的证据抹掉。
   事后无法回答"幕帘是几点、被什么停掉的"。
3. **没有任何东西盯着幕帘。** 它不是常驻服务,掉了没人知道,也没人拉回来。

### 修复

- `on` 在**调暗之前**做辅助功能预检,失败时打印 TCC 归责链并给出对策。
  原来的失败路径是"四块屏黑掉 → 阻断器起不来 → 回滚",而回滚本身也可能失败。
- `doctor` 增加:归责链、授权预检、安装物与 `install.sh` 清单的一致性、
  ad-hoc 签名告警、`hid-blocker` 自身 TCC 条目的 cdhash 匹配。
- 日志改轮转(`$LOG.1`),并新增 `last-run` 记录每一轮的开始与结束原因
  (看门狗在阻断器意外退出时也会写)。
- 新增 `curtain-sentry`:launchd 每 5 分钟检查一次,发现"声明过期望拉上、
  但阻断器没在跑、且没有真锁屏"就告警。**判据用显式的期望标记,不用
  `HIDIdleTime` 猜人在不在** —— 合成事件会刷新 idle,恰恰在无人值守跑
  agent 时它永远是 0。告警出口 `CURTAIN_ALERT_CMD` 可接推送。
- 运维守则:**只从已授权的 Terminal.app 启用 curtain,不从 agent 会话启用。**

### 同一天的第二次掉线:部署把它拆了

当天稍晚,迁移到菜单栏 app 的安装动作退役了整套旧栈 —— 阻断器、提示条、
看门狗、看护全部删掉,**并且没有重新拉上幕帘**。四块屏回到全亮、会话解锁,
机器主人仍在外地,而且**同样没有任何东西提示**。

这一次和上一次的共同点值得记下来:**两次都不是进程崩溃**。
一次是启用失败后没人再管,一次是部署动作拆了没装回去。
两种情况下运行中的组件都无法自我报告 —— 崩溃可以靠 app 常驻来兜,
「根本没被装回去」不能。所以判据必须留在进程之外:

- `state/expected` 由 app 在拉上时写、**主动**拉开(off / 热键 / 到点自动解除)
  时清;崩溃、被卸载、被替换都到不了清除那一步。
- `curtain-sentry` 由独立的 launchd 任务每 5 分钟检查一次,
  直接连控制 socket 问状态,**刻意不走 `bin/curtain`** —— 后者在 socket
  不在时会 `open -gj` 把 app 拉起来,那会把「app 没了」这个故障掩盖掉。
- 安装脚本从「退役 sentry」改成「安装 sentry」。看护必须跟着部署一起装,
  否则下一次部署又会留下同样的窟窿。

## 10. 提示条崩溃:NSWindow 的 isReleasedWhenClosed

2026-09-02 11:18:50,`curtain-banner` 崩了:

```
EXC_BAD_ACCESS (SIGSEGV)  objc_release
  ← -[_NSWindowTransformAnimation dealloc]
  ← CA::Context::commit_transaction
```

崩溃前一条日志是 `AppKit:Screen NSApplication._react(to:) reactions=83`
—— 显示器重配置。`~/Library/Logs/DiagnosticReports/` 里同款报告共 4 份
(09-01 18:08 / 22:53 / 23:19,09-02 11:18),是复发性缺陷,不是偶发。

**根因:`NSWindow` 的 `isReleasedWhenClosed` 默认是 `true`。**
屏幕参数变化时提示条做 `windows.forEach { $0.close() }` 再 `removeAll()`:
`close()` 释放一次,数组的强引用被 ARC 释放时又一次 —— 双重释放。
崩溃点落在之后某次 autorelease pool 排空里,所以现场离案发点很远。

确定性验证(`tests/banner-lifetime.zsh`):用 weak 引用做判据,
数组仍持有窗口而 weak 被清零,即为提前释放。

```
isReleasedWhenClosed=true    close() 后 weak 已被清零 —— 悬垂引用   → 退出码 139
isReleasedWhenClosed=false   close() 后 weak 仍存活                → 退出码 0
```

**注意合成的 `didChangeScreenParametersNotification` 复现不出这次崩溃**
(实测发 8 遍,旧代码干净退出)—— `_NSWindowTransformAnimation` 只在真实的
显示器重配置里才会被 AppKit 建出来。所以判据要用生命周期,不要用"多发几次通知"。

修复两处:

1. `win.isReleasedWhenClosed = false` —— 真正的缺陷。
   (仓库里新的 `Sources/AgentCurtain/BannerController.swift` 本来就是对的。)
2. 屏幕数没变时只 `setFrame` 挪位置,不销毁重建。分辨率变化、显示器睡醒
   这类最常见的屏幕参数变化根本不需要重建窗口,顺带完全绕开了销毁路径。

## 11. 2026-09-06:「curtain 坏了」其实是两件事

当天 `curtain status` 回 `{"error":"command is not UTF-8","ok":false}`,`curtain on`
报「没有显示器」。看护日志回看,`state=unknown`(就是这个 not-UTF-8)从 09-02
17:44 起就零星出现,09-06 机器 load 294 时几乎必现。

### 11.1 控制 socket 的读竞态

`ControlServer` 给监听 fd 设了 `O_NONBLOCK`,而 **macOS 上 `accept()` 出来的连接
继承这个标志**(BSD 语义,Linux 不继承)。`serve()` 里的 `recv` 循环把
`count <= 0` 一律当 EOF —— 客户端的字节还没到,`recv` 返回 -1/EAGAIN,循环退出,
拿着空串去 `String(data:encoding:)`,得到 `""`,split 后 `first` 是 nil,于是报
「不是 UTF-8」。**错误文案指向了完全无关的方向。**

确定性复现:连上 socket 什么都不发,服务端立刻回错误 —— 它根本没等。

修法在 `ControlLineReader`:读之前清掉 `O_NONBLOCK`、设 `SO_RCVTIMEO`(5s),
EAGAIN 只在超时后才出现,并把「空命令 / 超时 / 不是 UTF-8 / 太长」分开报。
超时是必要的:`serve` 跑在串行队列上,一个不说话的客户端原本能把整个控制面卡死。
回归测试用 `socketpair` + 读端 `O_NONBLOCK` + 300ms 后才写,精确复现继承标志下的
晚到客户端。

### 11.2 重启后 BetterDisplay 没回来

08:46 机器重启。BetterDisplay.app 不在登录项里,没跟着起来。而 `betterdisplaycli`
只是个前端:**app 不在时它什么都不回、退出码还是 0** —— 静默失败。
`displayIDs()` 于是抛「没有显示器」,`curtain on` 死在调暗这步。
(至少是安全方向:没有调暗就不会阻断输入。)

AgentCurtain.app 同样不在登录项,但瘦客户端在 socket 不在时会 `open -gj`
把它拉起来;BetterDisplay 没有这条后路。现在 `BetterDisplayClient` 在拿到空的
显示器列表时,先 `open -gj /Applications/BetterDisplay.app`,轮询到 CLI 开口为止
(上限 10s),装都没装才报 `appNotRunning`。`doctor` 也会说 app 在不在。
launcher 做成可注入,测试里用假 CLI「前两次沉默、第三次开口」验证重试路径,
不会真的去开 app。

### 教训

- **错误文案要说读到了什么**,不要替读取失败编一个原因。「不是 UTF-8」让第一轮
  排查去查编码,而真相是「什么都没读到」。
- 一个只回空、退出码为 0 的 CLI 是最坏的依赖形态。对这种依赖要在**调用方**补上
  「空 = 不在」的判断,而不是指望它有一天会报错。
- 后续:`install` 现在把 BetterDisplay 和 AgentCurtain 都加进登录项(幂等),
  `doctor` 会检查两者在不在。自愈是兜底,登录项是正路。
- 常驻服务的依赖也得能自愈或至少自述。重启后少了一个登录项就整套失灵,
  而且没有任何提示 —— 这和 §9 是同一类问题:**不是崩溃,是没被装回去**。

