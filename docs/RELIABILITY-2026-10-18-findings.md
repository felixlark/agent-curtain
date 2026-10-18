# 2026-10-18 后续:五项遗留缺陷的源码修复

本轮处理 `docs/RELIABILITY-2026-10-18.md`「未处理」清单,对应 GitHub #1–#5。
基线 `eb0764d`。源码回归:28 XCTest + 47 Swift Testing;隔离套件
`window-session-recovery`、`coordinator-transitions`(10/10)、`sentry`、
`banner-layout`、`banner-lifetime`、`watchdog-integration` 全部通过。

## 修复

| 议题 | 问题 | 本轮处理 |
| --- | --- | --- |
| [#1](https://github.com/felixlark/agent-curtain/issues/1) | 亮度恢复审计在成功路径恒写 `error: nil`,校验窗(0.6 秒)之后的漂移被当成精确成功 | 校验窗从 3×0.2 秒延长到 5×0.2 秒,并在窗口关闭后再读一次(`BrightnessRestoration.restore`)。内置屏在此之后发生的移动记入 `BrightnessDrift` 并写入审计的 `drift`/`warning` 字段,不再以 `error: nil` 掩盖;外置屏自身移动仍视为失败。漂移同时经 `BrightnessController.lastRecoveryWarning` 出现在状态 `warning` 与菜单。 |
| [#2](https://github.com/felixlark/agent-curtain/issues/2) | 亮度恢复按完整库存匹配,而非活动屏幕 | `BrightnessRestoration.restore` 改为只匹配 `activeDisplays()`,与 `096828b` 的协调路径一致;对仍在上线的屏幕保留有界等待(3 次 × 0.5 秒)。审计的 `after` 同样改为只读活动屏幕。带注入 provider 的回归证明库存中非活动的 `displayID` 绝不被写入。 |
| [#3](https://github.com/felixlark/agent-curtain/issues/3) | `windowID == nil` 的保存窗口无法判定消失,形成永久 pending | 新增纯函数 `WindowSessionPlanner.unmatchedWindowDisappeared`:即使没有 WindowServer 身份,只要应用仍在报告窗口且这些窗口已被其它保存窗口全部占用,就判定为消失。应用尚未重建窗口(活动列表为空)时仍保持 pending,避免误报。 |
| [#4](https://github.com/felixlark/agent-curtain/issues/4) | 2px 严格容差下被应用夹取的窗口被反复记为失败 | 重试循环记录每个窗口的帧是否已停止变化;停止变化且满足 `isClampLimited`(目标超出可用区域、实际帧落在其中)的窗口计为**已恢复并记录偏差**(`WindowRestorationReport.deviations`),不再进入失败与 pending。无法归因的窗口仍按原样记失败。偏差写入窗口审计并出现在 `recoveryWarning`。 |
| [#5](https://github.com/felixlark/agent-curtain/issues/5) | 解锁末尾活动屏幕计数读取失败会整体标为「操作失败」 | `restoreProtectionStateLocked` 拆出 `warnings` 通道:显示器/亮度/窗口都已恢复后,仅用于回读诊断的计数失败记入 `recoveryWarnings`,不再计入 `CurtainRecoveryError`,因此 `status.ok` 保持为真、`activeDisplays` 回退为本次绘制记录的数量。启动路径的同类读取同样降级为警告。 |

## 验证

- `swift test`:28 XCTest(新增 3:无身份窗口的消失判定、有身份窗口的消失判定、夹取识别)+ 47 Swift Testing(新增 3:内置屏漂移被记录不致命、外置屏漂移仍失败、库存中非活动显示器不被写入)。
- `tests/window-session-recovery.zsh`:新增「夹取偏差被记录且不导致恢复失败」。
- `tests/coordinator-transitions.zsh`:新增「活动屏幕计数读取失败只是警告」,并断言 `ok == true`、`activeDisplays == 4`、`lastError == nil`。
- `tests/watchdog-integration.zsh`:看护恢复的亮度路径改走活动屏幕匹配,新增 `CURTAIN_WATCHDOG_ACTIVE_DISPLAYS` 测试缝(与既有 `CURTAIN_WATCHDOG_OPEN_EXECUTABLE` 同类),生产默认仍查询系统。

## 残余风险(需实机)

- 活动屏幕匹配依赖 `CGGetActiveDisplayList`;解锁后慢上线的屏幕现由 1 秒有界等待覆盖,若实机观察到更慢的上线,需要延长该窗口或改用连接状态。
  [#2](https://github.com/felixlark/agent-curtain/issues/2)
- 内置屏漂移被记录为警告而非失败,依据是「疑似自动亮度」这一未验证成因。若实机确认漂移来自可修复的原因,应把该分支改回失败。
  [#1](https://github.com/felixlark/agent-curtain/issues/1)
- 夹取判定要求目标超出可用区域;应用因最小尺寸而非可见区域夹取时仍会记失败。
  [#4](https://github.com/felixlark/agent-curtain/issues/4)
- 本轮未在实体机上执行启用/解除,未触碰安装版、TCC 或恢复备份。
