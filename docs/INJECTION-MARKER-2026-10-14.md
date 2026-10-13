# 暗号档执行报告（2026-10-14）

执行请求：`0346cffe-af78-4f81-9293-a5b05178f97e`。授权引用：`user:20261014-0052`。
执行电脑：实体 Mac `sol`；时间均为上海时间。实现、签名安装和真机测试已完成，成果交 Grok 验收；本报告不表示用户已接受。

## 候选与安装

- 分支：`main`；基线 `ec2ec5d`。
- `1fbcd7c`：会话暗号、协议、输入决策、持久化、菜单/横幅和测试。
- `a54031b`：解锁时等待真实 UUID 元数据，避免重复 `UNKNOWN` 导致断言崩溃。
- `096828b`：亮度协调只查询实际活动显示器，避免查询已断开外屏库存项。
- `954df31`：超时测试使用独立 POSIX shell 和明确的超时余量，保留强制超时及恢复断言。
- 最终安装版 `/Applications/AgentCurtain.app`：**1.1.4 (24)**，生产源码绑定 `096828b`；其后的测试和报告提交不改变安装版生产源码。
- Developer ID：`Developer ID Application: LONGBIAO CHEN (HJG65XBC25)`；Hardened Runtime、时间戳、稳定 designated requirement 均验证通过。
- 安装版与签名候选主程序 SHA-256 均为 `946ed3f02309828f94b62926de6d63d7ce73ec73c35328c631f1b81a4da97bba`。
- 更新了已有的 `~/.local/bin/curtain` 和 `/usr/local/bin/curtain`。安装使用现有非交互授权，没有密码提示，没有改变 TCC。
- 旧安装版、CLI 和起始状态备份：[本任务备份](</Users/longbiao/Library/Application Support/agent-curtain/backups/2026-10-14-marker-0346cffe>)。
- 保留基线中的全部无关未跟踪文件；没有新建或清理 worktree。

## 地基原型先行

在任何正式代码变更之前，单次 Swift 原型在这台 Mac 上建立 `.cghidEventTap`，发送带 `.eventSourceUserData` 的事件，并在 tap 中逐个核对整数值。鼠标移动（5）、左键按下（1）/抬起（2）、键盘按下（10）/抬起（11）均原样读回，结论为 **PASS all 5 event types**。

原型 tap 消费自己的测试事件，避免桌面副作用；已有 `listenAccess`、`postAccess`、`AXTrusted` 均为 true，无权限写入。
源码与原始回执：[prototype.swift](/Users/longbiao/Library/Logs/agent-curtain/2026-10-14-marker-0346cffe/prototype.swift)、[prototype-full.log](/Users/longbiao/Library/Logs/agent-curtain/2026-10-14-marker-0346cffe/prototype-full.log)。

## 礼部注入方式

```sh
curtain off
curtain on 30 --allow-marker >/dev/null
```

已 drawn 时重复 `on` 保留当前会话；切换档位需先 `off`。`on --allow-marker 30` 同样支持。

暗号文件：`~/.local/state/curtain/injection-marker`，即 `/Users/longbiao/.local/state/curtain/injection-marker`，权限 **0600**，私有父目录 **0700**。文件内容是有符号 64 位十进制整数，不能用 JavaScript Number 读回。控制响应同时返回 `injectionMarker`；报告和实测日志均不保存当前暗号值。

```swift
let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/state/curtain/injection-marker")
let text = try String(contentsOf: url, encoding: .utf8)
guard let marker = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
    throw CocoaError(.fileReadCorruptFile)
}
event.setIntegerValueField(.eventSourceUserData, value: marker)
event.post(tap: .cghidEventTap)
```

每个鼠标移动、按下、抬起及键盘按下、抬起事件都要设置暗号。测试投递使用 HID 流，未用 `postToPid` 绕过阻断器。[Apple `post(tap:)` 合同](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29)说明事件会经过该投递位置的 event taps；本机原型与正式计数验证了这条路径。

拒绝名单仍优先，物理 PID 0 仍阻断；没有暗号时沿用原白名单逻辑。旧 `--allow-any-injected` 已删除实现并拒绝解析。紧急热键仍在普通输入决策之前处理。open、自动解除、热键解除和失败回滚撤销暗号；启动恢复清掉失效暗号。watchdog、sentry、expectation 的看护实现未改。

## 测试结果

- 完整 `swift test --scratch-path ~/Library/Caches/agent-curtain/swiftpm-marker`：**23 XCTest + 43 Swift Testing，全部通过**。
- 覆盖暗号正确、错误、拒绝名单优先、无暗号旧逻辑；参数顺序、重复/未知选项、非法和非有限时长；Int64 极值响应编解码及旧响应兼容。
- 真实 Coordinator 源码配合依赖 fixture：**9/9**，覆盖 drawn、0600 文件、同一暗号进入 blocker/响应、open 清暗号和 expectation、失败回滚、菜单/横幅措辞及既有恢复转场。
- banner 生命周期与完整标签布局、窗口恢复、watchdog 故障恢复、sentry 回归均通过；watchdog 的 kill-9 仅用于测试自己的虚拟 owner 进程。
- 最终 `curtain doctor` **exit 0**。

完整日志：[证据目录](/Users/longbiao/Library/Logs/agent-curtain/2026-10-14-marker-0346cffe)。首次全套运行中的既有 100ms 超时 fixture 在负载下波动，定向运行通过；将测试 shell 与宿主启动配置隔离、首轮 sleep 改为 2 秒且命令 deadline 为 0.5 秒后，全套通过，没有删除断言或禁用用例。

## 最终安装版真机验收

经官方 Computer Use，通过 Finder“打开方式 → TextEdit”打开独立测试文稿，并用公开系统状态确认真实前台是 TextEdit。初次 TextEdit 仅在后台的尝试未作为通过证据。以下复验绑定最终生产源码 `096828b`。

| 操作 | 实际结果 | 控制计数 |
|---|---|---|
| 暗号档，带暗号点击粗体按钮 | 官方 CUA 读回粗体 1 → 0、Regular | allowed 0 → 3，blocked 0 |
| 同一点不带暗号点击 | 粗体维持 0，AX 状态不变 | allowed 3，blocked 0 → 3 |
| 带暗号点击文稿并逐键输入 `FINAL_OK` | 实际文稿显示 `MARKER_OKFINAL_OK`，CUA AX 与图片均读回 | allowed 3 → 22 |
| 不带暗号输入 `BLOCKED` | 文稿仍为 `MARKER_OKFINAL_OK` | blocked 3 → 17 |
| 不带暗号的 ⌃⌥⌘U HID 热键 | drawn → opening → open；暗号与 expectation 均删除 | 四屏恢复，22 窗口恢复，两个恢复队列均为 0 |

热键验收由授权的事件注入测试程序向 HID 流生成该组合，实际触发安装版解锁；没有声称由用户手按键盘。保护状态下成功绑定正式安装版横幅，官方 CUA AX 读回 `屏幕关闭·仅放行注入 ⌃⌥⌘U 解除`；原始图像显示左右红色翼区完整文案，普通档另读回 `屏幕关闭·输入锁定`。菜单/横幅文案与不截断布局另有转场和布局测试。open 状态没有横幅窗口时，菜单栏 App 的 CUA 绑定 timeout 不作为产品失败或验收通过证据。

官方 Computer Use 原始图片在本执行回执中；摘录：[cua-observations.txt](/Users/longbiao/Library/Logs/agent-curtain/2026-10-14-marker-0346cffe/cua-observations.txt)。实际保存并关闭的文稿：[AgentCurtain-marker-test.rtf](/Users/longbiao/Library/Logs/agent-curtain/2026-10-14-marker-0346cffe/AgentCurtain-marker-test.rtf)。对应 `accepted-*.json` 保留逐步状态与计数，暗号字段均脱敏。

## 实测中修复的恢复故障

1. 第一次解除触发 `EXC_BREAKPOINT / SIGTRAP`，崩溃栈定位 `DisplaySession.swift:306` 的重复字典键 `UNKNOWN`。看门狗重启应用并恢复现场。布局恢复改为等待已保存的真实 UUID，并对重复真实身份报可恢复错误；随后真机热键解除完成，未再发生该崩溃。证据：[crash-excerpt.json](/Users/longbiao/Library/Logs/agent-curtain/2026-10-14-marker-0346cffe/crash-excerpt.json)。
2. 普通 drawn 后出现 `display reconciliation failed: betterdisplaycli failed: Failed.`。亮度协调错误地查询 BetterDisplay 中已断开外屏的库存项；改为只查询 CG 实际活动屏。最终普通 drawn 的持续状态与 doctor 均正常。

这两项为完成本票解锁和“测完恢复原状”所需修复，未改看护链、白名单或拒绝名单。

## 恢复后的现场

普通模式，没有自动解除定时器；读回：

```json
{"ok":true,"state":"drawn","displayMode":"internal-only","activeDisplays":1,"displays":4,"denied":4,"allowed":22,"blocked":17,"restorePending":3,"windowRestorePending":21}
```

`injectionMarker` 字段不存在，暗号文件不存在；expectation 存在。drawn 期间的 3 个外屏和 21 个窗口为解锁恢复快照；已证明解锁后恢复队列变为 0。实际安装版及其 watchdog 继续运行，sentry launchd 作业保留，最近退出码为 0。

未读取 `smart-shadow.json` 或微信凭据，未操作微信，未调用 Computer Use 操作 Codex 桌面，未使用 codex-dispatch、广泛注入放行开关、force-push 或权限绕过。无密码/认证挑战待处理。代码和实测验收项已执行；Grok 的最终成果验收仍由 Grok 负责。

代码和报告已按既有发布授权推送到 `origin/main`。该分支没有 GitHub Actions 工作流文件，`gh run list --branch main --limit 3` 返回空数组；没有现存 CI 运行待跟进。
