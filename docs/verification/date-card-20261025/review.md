# 日期卡片审查（2026-10-25）

审查当前未提交的日期块实现、Dart/Rust投影、JSON交换、设置会话、渲染和已有测试。
本轮不修复产品代码；天气块与分类文档的并行工作保持原样。此前已明确列出的浮动定位/复杂容器、装饰精确复刻和完整自定义输入缺口不重复当作本轮新缺陷。

## 发现

### R1 / P1：极小点线宽度导致UI绘制循环失去实际次数上限

位置：`packages/cses_document_collab/lib/src/ui/modal/collab_date_card_visual.dart:368`、`:380`。

导入的日期props允许保留`bw: "1e-320px dotted"`，当前JSON转换和日期投影能够将它传入真实日期画笔。
画笔只检查宽度有限且大于0，随后以`width * 3`递增点线偏移；正常卡片周长下需要天文数量的迭代。
每轮都同步执行`PathMetric.extractPath()`和`Canvas.drawPath()`，因此实际打开/绘制这种卡片会长期阻塞UI线程。
这不是显式编辑命令的白名单问题：读取既有/导入数据会绕过写入命令校验，旧的简化日期展示没有这个循环。

反例在真实JSON decode后构建Offstage日期组件，取得其真实foregroundPainter，再使用最多允许10000次drawPath的Canvas替身调用原始paint。
测试在第10001次主动终止，实际结果为`PAINT_BUDGET_EXCEEDED`，避免让测试或应用跑完危险循环；没有执行一次无限耗时的真机渲染。

建议在展示端规范化边框外观，对未知值安全回落，并为线段步长/绘制总数设置明确上限；保留原共享属性，不在读取时回写数据。

### R2 / P2：重选当前样式会抹掉已有缩放尺寸

位置：`packages/cses_document_collab/lib/src/editor/collab_date_card_settings.dart:127–135`。

已保存的台历为`width=336, height=289.504`（桌面默认固定框的2倍）。打开日期设置，滚动到“台历”按钮，点击本来已经选中的台历，再应用，结果变成`168×144.752`。
共享分段控件会回调当前已选值，`_change()`没有判断实际样式是否变化，就按默认样式尺寸覆盖width/height并持久化，额外产生撤销项。
用户没有要求恢复尺寸，手机一次外观确认就会改变桌面作者排版；这与未来是否开放手机拖拽无关。

建议仅在真实样式/格式切换时执行相应几何重算，已选值重选应保持当前尺寸和历史。

### R3 / P2：字号选择未使用卡片contentScale换算

位置：`packages/cses_document_collab/lib/src/editor/collab_date_card_settings.dart:181–196`。

日期字段`fs*`保存未缩放设计像素，桌面面板用`contentScale`换算显示字号，写回时除以倍率。
手机直接把设计字号作为显示选择，并将所选数字原样写入fs字段。

在2倍台历上选择“日期字号32”并应用，手机写`fsCalendar: "32.0"`；桌面按倍率显示64px。
同版发布工具`storeDateCardFont('calendar', {}, 'day', 32 / 2)`返回`{"fsCalendar":"16"}`，才是32px显示字号的契约。
因此卡片有缩放时，面板回显及写回都与实际显示不一致。首轮没有开放手机尺寸编辑，也仍会接收到桌面已缩放的普通流式卡片。

建议在显示端乘以有效内容倍率，写回时除以该倍率，并沿用切换样式后倍率重置、按样式稀疏存储及恢复默认规则。

## 验证依据

- [审查反例源码](review_probe_test.dart.txt)：三个“期望正确行为”的Widget反例，当前均失败，0通过/3失败。
- [完整反例输出](review-probes.log)：尺寸从336变168、字号换算得到64而非32、危险画笔第10001次绘制被替身主动终止。
- [发布版字号纯函数对照](review-desktop-font.json)：预期fsCalendar=16、实际手机fsCalendar=32.0。
- [目标静态分析](review-analyze.log)：日期四个核心实现文件与反例共五个目标无诊断。静态通过不覆盖上述行为缺陷。
- [现有日期/原生/JSON回归](review-existing-tests.log)共18通过/1失败：日期块与原生两个文件共14项通过，JSON其余4项通过；混合shape/columns/date/person/weather实际渲染用例仍失败（滚动查找No element），不计入本轮三条日期缺陷。最初尝试被并行天气改动在`collab_block_delete.dart`引入的临时未定义变量阻断，[原始输出](review-initial-compile-block.log)保留；后来编译错误消失并完成上述复跑，没有由本轮修改共享实现。

反例以.dart.txt归档在docs内，不放入正式test目录，避免未修复的正确行为断言影响默认测试发现及源码扫描。
复现时从包目录临时复制到`test/date_card_review_probe_test.dart`，运行`flutter test --no-pub test/date_card_review_probe_test.dart --reporter expanded`，之后移回归档目录；切勿改成断言错误行为来获得通过。

## 上游与范围

本轮重新查询桌面配置仓库：latest=0.11.30；桌面声明/Yarn锁0.11.28，实际安装0.11.21，历史pnpm锁0.2.78，未升级。
读取三版随包日期技能、相关MIGRATIONS以及字号、设置倍率、边框和Schema实现；相关片段指纹一致，发布产物SHA1与实时dist一致，见[review-version.json](review-version.json)。

只新增审查证据和文档跟踪，没有修复Dart/Rust/桌面实现；日期四个核心文件的审查起末哈希相同。
本轮没有新增Android/iOS完整构建、真机、桌面UI或真实在线双端验收。日期保持“部分支持”，历史通过结论保留，但不能覆盖这三项新反例。

## 后续修复

2026-10-25：R1/P1、R2/P2、R3/P2已修复，原三条正确行为反例先独立通过，随后迁移底部弹窗。修改、41项回归及限制见[修复记录](fixes-and-bottom-sheet.md)。以上审查失败与当时指纹继续保留为历史证据。
