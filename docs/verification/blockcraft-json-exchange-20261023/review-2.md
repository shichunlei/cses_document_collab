# 双向 JSON 六项修复后的再次审查

后续状态：复查确认的RR1/RR2两项P1已完成[修复和完整性验证](p1-fixes.md)，本页保留当时的结论、失败证据与范围。

日期：2026-10-23。范围：当前工作区相对 `189ffad` 的六项修复、29项新增正式回归，以及必要关联的回车、硬件Tab、事务预检和实时树编码链。本轮仅审查；未修改生产实现、未提交或推送。

## 结论

仍确认2项P1数据完整性问题：R1的空标题回车转换遗漏，以及硬件Tab产生真实嵌套后JSON导出漏掉整个待办子树。前者说明业务/身份保留合同尚未覆盖所有原位类型转换；后者属于本轮进一步确认的既有交换链缺陷，不声称由六项修复新引入。

正式29项新增回归本轮全部通过（宿主10、共享包19）；复制嵌套容器的身份分配、撤销及重做额外探针通过。新增3个正确行为反例跨两层确认2个问题（宿主2个、包1个同源复现）。既有回归通过不能覆盖这些未加入断言的编辑路径。

| 编号 | 优先级 | 位置 | 问题 |
|---|---|---|---|
| RR1 | P1 | `packages/cses_document_collab/lib/src/editor/blockcraft_json_codec.dart:486` | 文字块有Delta时编码只处理行内内容，忽略真实子块；硬件Tab仍可创建该结构，宿主预检也允许通过。 |
| RR2 | P1 | `packages/cses_document_collab/lib/src/editor/collab_paragraph_editing.dart:123` | 空标题回车转正文的替换分支只生成段落样式字段，未沿用宿主业务字段、bc身份与元数据；R1修复仅覆盖菜单/快捷转换链。 |

## RR1：缩进后的待办及勾选状态从导出中消失

宿主导入三个块：`first`正文anchor、`second`正文body、`third`已勾选待办todo。选中最后待办并执行正式硬件Tab对应的`indentCommand`，事务成功，实时树中的`[0,1,0]`仍为todo_list、checked=true，身份仍为third。

生产视图先注册`collabParagraphTabCommand`，其普通文字筛选对todo返回ignored；完整文档配置保留structuralIndentation=true，随后标准`indentCommand`会把待办放到前一文字块下面。共享包探针按这一真实命令顺序逐项确认ignored→handled及当前嵌套结构。

此时`encodeBlock`在父文字块上只输出Delta，不再访问node.children。生产`journal.exportBlockCraftSnapshot()`返回成功，但完全没有third、todo及其checked信息；直接调用共享包`BlockCraftJsonCodec.encode`也复现。宿主`validateJournalDocument`使用同一编码器校验子树，没有检查文字叶块的真实后代，因而没有拒绝这一不可完整编码的事务。反向导入该输出将彻底缺失待办。

修复应让JSON交换文档的硬件缩进沿用平面depth合同，或完整转换真实嵌套结构；同时在预检/编码边界显式校验不能完整表达的树，避免成功返回删减后的快照。仅保留原始JSON不能解决当前编辑树丢失问题，也不符合用户要求。

证据：[宿主实时树与导出](review-2-todo-tab.json)、[宿主最终反例](review-2-host-final-probes.txt)、[共享包命令顺序反例](review-2-package-final-probes.txt)。

## RR2：空标题退出仍丢业务和稳定身份

以生产导入器和LocalJournalController打开空H2：块ID=paragraph，meta.audit=demo，业务为help、entry-demo、guidance_done=false。调用公开`handleDocumentParagraphEnter`，可见类型确实转为paragraph。

该分支删除旧标题后调用`paragraphNode`，在nextParagraphStyle=body时仅传collabParagraphKeys的重置值，没有使用新补的blockConversionPreservedAttributes合同，也没有继承bc.id/bc.m:*等字段。导出的business={}、audit消失、ID变成新随机值。宿主合法性检查接受该空业务正文，因此丢失也可进入自动保存。

这不是“新增下一段应使用新身份”的情形：这里替换的是原路径上的空标题。需要将这一原位转换接到相同的业务/元数据/稳定身份保留链，并补充空标题及空引用的回车转换、撤销重做和保存重开回归。

证据：[回车后的节点与导出](review-2-heading-enter.json)、[宿主最终反例](review-2-host-final-probes.txt)。

## 验证与复跑

- 本轮正式回归：宿主10项通过、包19项通过，分别见[宿主日志](review-2-host-final-probes.txt)及[包日志](review-2-package-regressions.txt)。宿主同一次运行还包含额外1项成功的复制容器身份/撤销/重做探针与2项失败反例，合计11通过/2失败。
- 共享包Tab探针1项失败，正确行为断言为导出仍含todo；前置断言已确认真实命令回退、节点类型与checked=true。
- 两份探针静态分析无问题；已按宿主/包各自格式要求格式化。`git diff --check`通过。
- [宿主探针源](review-2-host-probes.dart)、[包探针源](review-2-package-probes.dart)已归档并从自动测试目录移除，避免审查把预期失败测试混入正式回归。
- 复跑：将宿主源复制为`test/daily_guidance/blockcraft_review_2_probe_test.dart`，在根执行`flutter test --no-pub test/daily_guidance/blockcraft_review_2_probe_test.dart test/daily_guidance/journal_blockcraft_editing_test.dart`；将包源复制为`packages/cses_document_collab/test/blockcraft_review_2_probe_test.dart`，在该包执行`flutter test --no-pub test/blockcraft_review_2_probe_test.dart`。宿主探针会在同主题目录重新生成两份反例JSON。
- 首次包探针缺少KeyEventResult的正确导入，编译失败保留为[诊断日志](review-2-package-initial-compile.txt)；已修正后复跑，不把编译失败当功能证据。首次宿主探针直接比较整个导出包含updatedAt差异，修正为比较children后复制容器测试通过；原诊断[保留](review-2-host-probes.txt)，不将其算作缺陷。
- 本轮不重跑全包、构建、桌面模型或设备；前轮全量和构建结果保留在[修复记录](fixes.md)，不据此声明新反例通过。

## 版本核对与范围

桌面配置仓库实时latest=0.11.30、integrity未变；桌面根声明/Yarn锁0.11.30、安装0.11.17，历史pnpm0.2.78；docs工作区自身声明仍为^0.11.0-alpha。安装版/最新发布产物随包技能、MIGRATIONS及快照实现指纹与前轮一致，复核结果见[版本记录](review-2-version-verification.json)。沙箱内首次DNS查询失败后，获准的只读查询成功；未写桌面依赖。

本轮复读L0/adapter、数据指南/迁移契约并检查editable.children与模型快照分支；.30仍为静态核对。本轮未新增桌面运行、FRB、真机、iOS或真实在线验收，上游组合域、图片gap、菜单输入/历史协同及高级对象/Vectra限制继续保留。正式42块及13已适配/28部分支持/1结构支持/0未适配统计不变，相关JSON限制同步到适配表。
