# AgentCurtain 菜单栏应用验收矩阵

更新：2026-10-13，Asia/Shanghai。原始要求归 [PRD](PRD-menubar-app.md)，
单内屏拓扑扩展归 [显示断开设计](PLAN-display-disconnect-backend.md)。
源码、自动测试、安装运行、真实设备和用户接受分别举证；旧记录不能冒充当前现场。

## 当前基线与本轮证据

- 系统入口：[AgentCurtain 正式安装版](/Applications/AgentCurtain.app)。本项目是
  sol 本机菜单栏应用，没有 Web 页面；打开 app 后点击菜单栏眼睛图标，已运行
  时直接点击。无需产品账号登录；远程先用已有 UU 会话连接 sol。按追加请求
  `d00ce1d0-5c59-4db9-999f-5dcd96e73584`，回执优先给该入口，不录屏；
  下述截图为追加指示前已取得的辅助记录，保留原证据。
- sol 的 canonical checkout：`0b3fefc5548038e8cd53e6064462aeb225dc9103`，
  已与远端 `origin/main` 读回一致，包含 v1.1.1–v1.1.3 修复。
- 正式安装路径 `/Applications/AgentCurtain.app`，版本 1.1.3；主程序 SHA256：
  `05a8489b87e4e9067646f3515c3353b0e1f873ae301f24bc611d9784ad6946a3`。
- `curtain doctor` 通过：Developer ID requirement 无 cdhash、socket 0600、
  BetterDisplay 运行、system-spi 可用、Pro off。本轮没有重装或修改 TCC。
- 10:53 读回 `state=drawn`、`activeDisplays=1`、`displays=4`、
  `restorePending=3`、`windowRestorePending=7`。保护状态下的这些 pending 表示
  当前会话保存的恢复对象，不能据此认定解除失败。另有旧布局归档 warning，
  归档不代表恢复成功，亦不代表这 7 个当前对象全部来自旧故障。
- 官方 Computer Use 读取真实安装版横幅，截图保存于
  [安装版横幅](/Users/longbiao/Documents/Development/office/demo-20261013/agent-curtain/01-installed-1.1.3-protected-banner.png)。
  现有 ScreenCaptureKit framebuffer 验证器在唯一活动内屏 `displayID=1`
  检出 7,277 个 `#BF1A1A` 特征色像素，PASS。只证明当前活动内屏渲染，
  不证明外屏物理亮度、远程刷新或实体输入行为。
- 当前源码 `swift test --scratch-path`：23 项 XCTest、36 项 Swift Testing，零失败。
  此为源码逻辑回归，不能推断已安装二进制与这次重新编译产物逐字节一致。

本轮日志和状态快照：
[验收记录目录](</Users/longbiao/Library/Application Support/agent-curtain/acceptance/2026-10-13/>)。
版本、哈希、截图哈希与请求 ID 见
[证据清单](/Users/longbiao/Documents/Development/office/demo-20261013/agent-curtain/evidence.json)。

## PRD §9 与设计扩展对照

| # | 验收项 | 可复核证据 | 当前结论与缺口 |
|---:|---|---|---|
| 1 | 授权一次后重编译仍有效 | 既往 1.1.2/1.1.3 签名安装和真实开关循环，见两次可靠性记录 | 既往安装路径通过；本轮未升级，不能新增重编译后授权证据 |
| 2 | requirement 无 cdhash | 本轮安装物 codesign、doctor | 通过 |
| 3 | 调暗及显示拓扑 | 10-10 的 4→1→4 审计；本轮 status 只有一个活动屏 | 拓扑状态通过；本轮未逐屏读亮度，物理外屏确认待验 |
| 4 | 保护期间截图有真实内容 | 本轮安装版横幅截图及内屏 framebuffer 特征色 | 当前内屏横幅可捕获；完整桌面持续刷新与 UU 端仍待验 |
| 5 | 提示条真正渲染 | 本轮 displayID=1、featurePixels=7277 PASS | 当前单内屏模式通过；不外推到离线外屏 |
| 6 | 物理键鼠无响应 | 仍缺真人 HID 操作 | 待实体操作，blocked=0 不是阻断失败的证据 |
| 7 | 白名单远程桌面放行 | 状态有 allowed 计数，尚缺本轮 UU 端操作录像 | 计数不代替真人远程输入验收；今晚核验 |
| 8 | deny 优先 | 原纯函数单测及本轮全套源码回归通过 | 逻辑通过；真实注入进程的 allow+deny 路径仍待验 |
| 9 | 解除不需要 TCC | 既往未授权 shell 走控制 socket off 成功 | 历史路径通过；今晚继续读回公开入口 |
| 10 | 崩溃后显示/亮度恢复 | 显示断开计划中已有本机 kill -9 记录 | 历史通过；本轮未强杀保护会话，不称本轮崩溃验收 |
| 11 | 热插拔恢复 | 既有实现与源码回归 | 真实插拔、睡眠唤醒仍待专项实机验收 |
| 扩展 | 窗口归位 | 10-10 同候选 8 个窗口几何一致；本轮保留 7 个当前恢复对象 | 今晚比较前后窗口几何和审计；pending=0 不能单独证明 |
| 扩展 | 实体 L/U 热键 | 代码、菜单、横幅使用 ⌃⌥⌘L/U；既往合成事件不触发 | 今晚用实体键盘或 UU 发送组合键，合成输入不能关闭此项 |
| 扩展 | 内屏亮度 | 10-10 内屏总亮度 0.891→0.932，成因未验证 | 今晚逐 UUID 核对保存值及恢复审计；不擅改自动亮度策略 |

历史依据：[10-09 故障复盘](RELIABILITY-2026-10-09.md)、
[10-10 元数据恢复修复](RELIABILITY-2026-10-10.md)、
[显示连接后端与实机记录](PLAN-display-disconnect-backend.md)。

## 下一里程碑

v1.1.3 后的下一里程碑为**保护与解除的实机可靠性验收**，沿既有设计关闭
实体热键、UU 单屏操作、窗口归位及亮度的证据缺口，详见
[推进计划](PLAN-post-v1.1.3.md)和
[今晚确认清单](/Users/longbiao/Documents/Development/office/agent-curtain-实机确认-20261013.md)。
本轮新增只读快照工具，补齐当前安装版横幅证据并校正清单。
产品仍为 1.1.3；Grok/用户尚未接受下一里程碑，未宣称完整硬件验收通过。
