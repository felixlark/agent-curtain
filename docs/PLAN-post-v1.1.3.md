# v1.1.3 后的下一里程碑：保护与解除的实机可靠性验收

来源：2026-10-13 shadowd 请求 `d752bc96-43c7-4cf0-ae55-041b5907d95b`。
验收方：Grok。执行电脑：sol。范围依据 [PRD §5/§9](PRD-menubar-app.md)、
[显示断开设计 §7/§9](PLAN-display-disconnect-backend.md)、
[10-10 恢复记录](RELIABILITY-2026-10-10.md)。

## 需求分析

已有 1.1.3 修复窗口元数据暂态失败，下一步优先完成原有用户旅程的实机确认。
本轮最短可看结果是：真实安装版保护横幅截图、framebuffer 正例、可复用的
步骤前后只读快照，以及与最新基线一致的今晚清单。

下一里程碑验收条件：

1. 实体/UU 组合键 U 能解除、L 能启用，并记录触发来源。组合键被本地电脑
   截走与 app 失效分别定位；CLI 兜底成功不替代快捷键通过。
2. 保护期间 UU 只有一个持续更新的画面，白名单远程输入可用。
3. 解除后逐 UUID 对比显示布局、逐窗口核对恢复几何；未知对象保留并失败，
   不靠 pending=0 单独判定。旧归档不自动回放到新进程。
4. 比较保存值与恢复审计的总/硬件/软件亮度，明确内屏漂移是否复发。
5. 记录是否出现操作失败横幅；最后状态按用户现场选择，读回并释放桌面控制。

这次确认不代替真人物理键鼠拦截、热拔插、整夜睡眠及所有应用组合的专项验收。

## 架构设计

保持菜单栏 accessory app、HID 拦截、0600 本地 socket、UUID 显示恢复、
内核 PID 身份校验和现有 watchdog。验收工具只读既有 `status` 协议、
安装物身份与恢复文件摘要；不新增服务、协议、持久化格式或产品能力。
没有已复现的新产品缺陷时，不为了截图修改恢复策略或升级版本。

## 软件建模与本轮增量

新增 [capture_acceptance_snapshot.py](../script/capture_acceptance_snapshot.py)：
每次人工步骤前后显式运行一次，输出带时间、安装版本/主程序哈希、签名结果、
状态、备份数量/哈希及现有审计引用的 JSON。只有 `status` socket 命令；
连接/解析失败记录错误并非零退出，不启动 app、不写恢复文件、不发 on/off。
输出文件 0600、独立命名，避免覆盖之前的步骤；不复制窗口标题或应用文档内容。
快照按顺序读取，并非跨文件事务，采样时若产品正在切换需标注过渡状态。

```sh
python3 script/capture_acceptance_snapshot.py --label before-unlock
# 用户执行今晚清单中的实际动作后
python3 script/capture_acceptance_snapshot.py --label after-unlock
```

默认输出到 `~/Library/Application Support/agent-curtain/acceptance/YYYY-MM-DD/`。
可通过 `--output-root` 显式指定审计目录。工具只保存摘要；窗口几何、显示布局
和亮度的最终核验仍需读取产品原有恢复审计，不能以这个快照代替。

## 测试验收

本轮已完成：

- canonical `0b3fefc` 源码回归：23 XCTest + 36 Swift Testing 通过，缓存显式放在
  `~/Library/Caches/agent-curtain/acceptance-20261013/`。
- 真实安装版 1.1.3、Developer ID requirement 无 cdhash、doctor 通过。
- 官方 Computer Use 安装版横幅截图；现有 framebuffer 验证器的活动内屏正例
  `displayID=1 featurePixels=7277 PASS`。
- 快照工具在真实保护会话上执行；输出结构、0600 权限、备份 hash 不变及
  错误路径的实际验证结果见 demo 回执。

本轮没有改变安装物，也没有执行解除/重启/强杀或显示拓扑切换，保留今晚
“先解除”的有效现场。截图与证据位于
[demo 目录](/Users/longbiao/Documents/Development/office/demo-20261013/agent-curtain/)。

## 运行维护与今晚配合

沿用 [21:00 清单](/Users/longbiao/Documents/Development/office/agent-curtain-实机确认-20261013.md)。
现场从当前真实状态开始，不强行假定仍为 drawn；只有实际解除后继续存在的
pending/错误才进入故障复盘。既有恢复归档完整保留，亮度未知不写成一致。

若出现新错误：保存该步骤快照及原审计，先按现有公开 off 恢复可用状态，再
回到需求分析，针对可复现故障设计、实现、验证。正常路径和兜底路径分开举证。
本轮不新增定时任务或独立 chat；21:00 用户/工部在原任务实际触发确认后，
本线程可继续取步骤证据。计划存在不等于届时已有自动执行机制。

当前结论：最短可看一步已交付；下一里程碑仍待真实热键、UU 端和恢复结果确认。
版本发布条件是相关原需求证据关闭及 Grok 验收，不先凭空指定 v1.1.4 新功能。
