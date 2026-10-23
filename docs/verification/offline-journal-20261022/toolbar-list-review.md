# 键盘菜单与日记列表代码审查

日期：2026-10-22。审查当前未提交的键盘菜单、原生用户提及及列表互转改动。任务开始前的视频修改与Android启动排查不计入本次功能审查。仅追加审查证据和版本/分类记录，未修改生产或正式测试。

后续状态：2026-10-23已处理R1～R3，见[修复与验证](../offline-journal-20261023/review-fixes.md)。以下保留当时发现和失败证据。

## 发现

### R1 / P2：原生选人未永久作废中途变化的账号会话

位置：[local_journal_page.dart](../../../lib/src/daily_guidance/local_journal_page.dart)的`_pickMentionUser`，297–301行传入的`canEdit`只反映编辑器权限，303–310行仅在返回时检查当前账号。

真实页面探针打开原生选择器后，将`ctx.cookieId`切到另一会话，等待450毫秒，再恢复原cookie并选择已有人员。实际正文由`原文`变为`原文\uFFFC `，且旧编辑器仍可编辑。旧业务选择器每200毫秒检查宿主账号条件并永久锁定失效；原生路径没有等价的账号代次或失效标记，因此切走再切回会让旧请求重新有效。

应让原生选择会话追踪宿主身份变化，一旦变化永久作废；不能只比较返回时的最终身份。

证据：[失败断言](toolbar-list-review-account.txt)、[真实页面探针](toolbar-list-review-account-probe.dart.txt)。

### R2 / P2：原生提及姓名在大字模式重复缩放

位置：[editor_user_mentions.dart](../../../packages/cses_document_collab/lib/src/editor/editor_user_mentions.dart)的`decorateEditorUserMention`，126–132行；日记在[guidance_entries.dart](../../../lib/src/daily_guidance/guidance_entries.dart)69行接入它。

日记外层`WidgetSpan`随正文缩放，原生姓名内部`Text`又继承系统`TextScaler`。2倍字号时，姓名内部的16像素先放大到32，外层再乘2，实际为原字号4倍；普通正文和旧业务引用只放大2倍。相同单行布局中，普通正文/旧引用高度为64，原生提及高度为80，姓名明显大于邻近正文，横线行距被撑开。旧引用明确使用`TextScaler.noScaling`，新原生分支没有对应处理。

应统一内外缩放职责，使原生姓名和头像的可见尺寸与正文缩放一次即可。

证据：[六样本对照日志](toolbar-list-review-layout.txt)为5通过、原生2倍样本失败，包含字号、TextScaler和相对父正文变换实测；[探针](toolbar-list-review-layout-probe.dart.txt)。未使用真实网络头像。

### R3 / P2：快速连续点击可绕过宿主动作等待互斥

位置：[stable_mobile_toolbar.dart](../../../packages/cses_document_collab/lib/src/editor/stable_mobile_toolbar.dart)217–219行只在重建时把按钮回调置null；267–280行执行时不校验禁用状态，已打开的子菜单也没有等待中的动作保护。

使用两个真实`tester.tap`，在下一帧前先点击尚未完成的宿主动作，再点击T。重建后T按钮虽已禁用，子菜单仍然可见；继续真实点击Todo，正文立即变为`todo_list`，宿主Future仍未完成。仅在下一帧禁止顶层按钮，不能保证新API承诺的操作互斥。

应在执行入口同步校验当前busy状态，并在禁用期间关闭或禁用已有子菜单，而不是仅改变顶层按钮外观。

证据：[独立复跑日志](toolbar-list-review-pending.txt)、[真实点击探针](toolbar-list-review-pending-probe.dart.txt)。该探针源码最初未另存，后从原始执行记录逐字恢复，并由主审再次运行验证，故不是声称的运行前源码快照。日志中的“通过”是对不应发生的绕过行为进行反例断言，不表示互斥实现正确。

## 其他核对与排除项

- 列表互转显式容器授权、同父整批校验、已有root/callout范围及Enter/Backspace/缩进隔离未发现新的确定问题。
- 原生对象命令解析移位仍在验证/应用前执行；未将既有其他对象返回值等历史问题算成本轮新回归。
- 真实IME键入@后选择或取消，再继续输入的两条路径通过，未复现重复@或旧输入回调覆盖：[日志](toolbar-list-review-ime.txt)、[扩展后的探针](toolbar-list-review-ime-probe.dart.txt)。
- IME用@替换组合中的`xin`时保留旧拼音的候选问题，经git HEAD旧正文组件及等价旧选人流程证实同样存在，因此不列为本轮新增finding。保留[当前反例](toolbar-list-review-ime-existing.txt)、[基线对照](toolbar-list-review-ime-baseline.txt)、[基线探针](toolbar-list-review-ime-baseline-probe.dart.txt)和[HEAD正文组件](toolbar-list-review-head-surface.dart.txt)。HEAD组件只将同目录import改为当前包路径供临时探针解析，不改正文逻辑。

## 版本、来源与验证边界

本轮通过桌面配置仓库独立缓存实时查询latest=**0.11.28**；声明/Yarn锁**0.11.28**、安装**0.11.21**，发布integrity与已核对产物一致。复核安装版/发布版随包技能、迁移说明、菜单及行内实现，未改桌面依赖。上游对象动画、其他Schema/输入/历史/协同差异继续按原待办处理；正式块41及13/14/1/13统计不变。

27个相关手写文件与最近有效验证指纹一致，其中19个生产源与最近APK完全一致。前轮475项包关联及137项日记测试未覆盖上述反例，本轮不凭其通过记录声明可提交。没有重新构建、安装、实测物理设备/iOS/真实在线双端或服务器ACK；新增探针均为Flutter测试环境和虚构资料。

[结构化结论](toolbar-list-review.json)、[审查源码指纹](toolbar-list-review-source-sha256.json)。临时探针没有留在正式test目录；归档文本仅统一控制符和行尾空格，保留失败及对照结论。
