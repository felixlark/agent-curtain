# 2026-10-10 解锁窗口恢复修复

最新解锁错误记录于 10:44（Asia/Shanghai）：`window restore failed: application metadata unavailable for live pid 3035`。运行版本为安装路径 `/Applications/AgentCurtain.app` 的 1.1.2，四屏已恢复，但四个窗口仍待恢复。

## 证据与原因

原窗口快照来自 10 月 9 日 21:21。内核和进程列表确认 PID 3035 的 Safari 仍存活，Chrome、Grok Bot 和 ChatGPT 也仍是原进程。独立 AppKit 查询随后可解析这四个 PID；在未重启安装版或目标应用的情况下重试解除，四个窗口全部恢复。因此可以确认应用元数据查询发生了暂态失败，但不能据此确定 macOS 内部哪个组件触发该失败。

代码中 `managed.filter` 的应用身份查询会抛出错误，导致一个应用的暂态失败中断整批恢复；随后按应用枚举 AX 窗口也有同样的失败传播问题。

## 修复

- 元数据缺失最多查询 11 次，间隔 0.1 秒；每次都重新核验内核 PID 生命周期。明确身份不匹配、未知启动时间仍立即失败；PID 已退出或重用不作为原窗口目标。
- 初次身份筛选及后续窗口枚举均按应用隔离失败。其他应用继续恢复，未知对象保留到失败队列与审计，不记作消失。沿用此前仅重试未恢复窗口的持久化机制。
- 日常安装版升级至 1.1.3，保留 Developer ID 身份、已有 TCC 和原快捷键。

本次修改位于 `Sources/AgentCurtainCore/WindowSession.swift`、`tests/AgentCurtainCoreTests/WindowSessionTests.swift` 和 `script/build_and_run.sh`。修复前既有未提交工作已保留，未将其代为提交或推送。

## 验收

- 23 项 XCTest、36 项 Swift Testing 全部通过。新增用例覆盖暂态缺失后恢复、持续未知仍失败、重试期间 PID 重用、身份不匹配、未知启动时间，以及单应用失败不阻断其他目标。
- 窗口控制器隔离回归 4/4、状态机回归 8/8，以及崩溃看护隔离集成通过。
- 签名安装候选与 `/Applications/AgentCurtain.app` 的主程序 SHA256 一致；`curtain doctor` 通过。
- 同一安装候选真实执行 4→1→4：8 个窗口全部恢复，逐 PID/windowID 比较前后几何一致；四个显示器 UUID 对应 bounds 完全一致，无假消失和未恢复对象。
- 三块外屏总亮度、硬件亮度、软件亮度审计均与保存值一致。内屏恢复过程未报错，但随后审计的总亮度 0.891→0.932、硬件亮度 0.863→0.914 有变化，未验证其成因，不能宣称内屏最终亮度精确一致。本次修复针对窗口元数据失败，不改亮度或自动亮度策略。
- 官方 Computer Use 确认真实保护横幅 `屏幕关闭·输入锁定 ⌃⌥⌘U 解除`，以及恢复后的 Safari、Finder 菜单交互。未使用 GUI 自动化替代框架。
- 最终 `ok=true`、`state=open`、`activeDisplays=4`、`restorePending=0`、`windowRestorePending=0`，保留正常开放现场。

此次真实循环验证当前恢复路径；不声称覆盖整夜睡眠、所有应用组合或实体键盘热键。元数据持续不可用时仍会保留该应用的失败并报告，不绕过身份核验。

完整证据：`~/Library/Application Support/agent-curtain/incidents/2026-10-10-unlock/`。包括原始失败快照、原安装版备份、既有改动基线、测试与安装日志、循环快照及审计、候选哈希、签名和最终状态。
