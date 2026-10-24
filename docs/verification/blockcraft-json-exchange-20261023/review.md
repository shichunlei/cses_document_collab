# 提交189ffad审查

后续状态：R1～R6已完成[修复和双向验证](fixes.md)。本文保留原审查时的失败结论与证据。

日期：2026-10-23。范围：`189ffad feat: 实现今日导向与桌面JSON双向转换`，覆盖新增Codec、正式节点投影、宿主导入/导出/编辑与锁保护，以及原生行内渲染。本轮仅审查，不修改生产实现、不重新提交或推送。

## 结论

确认6项功能缺陷：2项P1、4项P2。原有往返示例和回归通过只覆盖此前断言，不能证明编辑后所有字段都正确重新导出；这些反例不在旧测试的覆盖中。已明确列出的独立Vectra图正文、高级对象工具和实时业务源限制不重复记作新缺陷。

| 编号 | 优先级 | 代码位置（仓库相对路径） | 已确认的问题 |
|---|---|---|---|
| R1 | P1 | `lib/src/daily_guidance/journal_draft.dart:10` | 导入后的能力配置直接换为EditorConfiguration.document，丢掉原日记类型转换时的业务字段保留合同；标准转换也不保留bc身份/属性/元数据。 |
| R6 | P1 | `packages/cses_document_collab/lib/src/editor/blockcraft_json_codec.dart:433` | 新任务卡片的引用存于cses_resource，但编码分支未读取task的专属资源模型，导出props为空。 |
| R5 | P2 | `lib/src/daily_guidance/local_journal_controller.dart:458` | 插入末尾时op.path尚无节点，祖先锁遍历从null开始，整个父容器锁检查被跳过。 |
| R3 | P2 | `packages/cses_document_collab/lib/src/editor/blockcraft_json_codec.dart:160` | 普通paragraph缺少明确映射，列表退级为段落后仍读取旧bc.flavour，重新导出恢复成todo/bullet/ordered。 |
| R2 | P2 | `packages/cses_document_collab/lib/src/editor/blockcraft_json_codec.dart:359` | 高亮块前缀及颜色在原生专用字段中更新，但导出仍读取导入时bc.p字段，输出旧值。 |
| R4 | P2 | `packages/cses_document_collab/lib/src/editor/blockcraft_snapshot_view.dart:68` | 无bc.e但有显式字重时提前返回纯TextSpan，后续人员/实体提及和公式的专用渲染被跳过。 |

## 复现与影响

### R1：导入稿类型转换丢失业务和块身份

生产导入器恢复带help业务的空段落，生产LocalJournalController打开后调用公开的applyDocumentBlockShortcut转H2。转换成功、节点确为heading，但guidance_entry_id从entry-demo变为null，再次导出的meta.mobileGuidance.business变为{}，原块ID也被新分配。包内实际T菜单共用的applyEditorBlockStyle另验证非空段落转H2：business、bc.id及原meta全部丢失。日记业务身份的丢失还会进入自动保存。

修复应为导入文档保留宿主业务合同，并在类型转换中延续已转换的块身份/元数据及仍适用的属性；不能仅增加一个heading映射。

### R6：新转换的任务卡片丢引用

用桌面task实体提及生成原生节点，通过正式convertCollabEntityMentionToCard转换为任务卡片。原生CollabTaskCard.read仍返回taskId=task-demo与title=任务探针，但BlockCraftJsonCodec.encodeBlock输出props={}。导出后再次恢复/交给桌面时丢失业务引用，无法显示或打开原任务。未编辑的导入任务卡片因bc.p残留而通过旧往返测试，遮蔽了新建卡片问题。

修复应从任务卡片的当前专用资源载体读取taskId/title等字段，并验证新增后导出及再次导入。

### R5：容器末尾插入漏掉锁检查

导入meta.lock=user-demo的callout，内部已有一个空段落。实际宿主guard能拒绝对旧段落插字，但在[0,0,1]追加新段落成功，锁定容器子块数从1变成2。插入位置不是一个已有节点，须从真实插入父容器开始检查锁，并对同事务前序操作后的目标进行正确定位。

### R3：退出列表后重新导出复活列表

导入checked=1、depth=0的空todo，调用正式outdentCollabListAtStart。当前原生类型已为paragraph，但重新编码flavour仍是todo，checked=1也保留。回到桌面或再次导入后，已退出的列表恢复。bullet/ordered通过相同fallback也受影响；同类特殊文本caption/shape-text/word-art仍应保留其专门规则。

### R2：可见外观和导出内容不一致

导入prefix=旧、backColor=#ffe6cd的callout，通过正式updateCollabCalloutAppearance将背景改为#112233、前缀改为新。当前原生字段正确变更，但重新导出仍是旧/#ffe6cd。相同编码路径未同步文字/边框色。应读取当前callout专用字段并正确处理清除值。

### R4：显式字重使提及消失

实际DocumentEditorView先显示普通人员提及“探针人员”；仅给同一原子增加已转换的s:fontWeight=600，界面可见姓名数从非零降到0。原子身份未被删除，返回纯TextSpan后只留下U+FFFC。应先合成外观，再继续同一原子的人员/实体/公式渲染，避免整个装饰器提前结束。

## 验证证据

- [review-package-final-probes.txt](review-package-final-probes.txt)：5个正确行为断言全部复现失败，分别是R1/R2/R3/R4/R6；均通过实际编辑命令或界面操作，而非伪造生产输出。
- [review-host-final-probes.txt](review-host-final-probes.txt)：2个宿主反例复现失败，为R1的真实导入控制器链及R5锁定容器末尾插入。7个失败断言对应6项独立缺陷，R1跨层重复验证。
- [review-package-probes.dart](review-package-probes.dart)、[review-host-probes.dart](review-host-probes.dart)：探针源代码归档，已从自动测试发现目录移除，避免本轮仅审查把预期失败探针混入正常测试集。
- 本轮探针目标静态分析、版本和源码指纹见[review-validation.json](review-validation.json)。最初探针误用不存在的Transaction.updateText导致编译失败、诊断print的lint信息均保留在独立日志；不将这些诊断算成功能复现结论。

复跑时将包探针复制到`packages/cses_document_collab/test/blockcraft_commit_review_probe_test.dart`，在该包执行`flutter test --no-pub test/blockcraft_commit_review_probe_test.dart`；宿主探针复制到`test/daily_guidance/blockcraft_commit_review_probe_test.dart`并从根目录执行相应测试。两者按正确行为断言，当前提交应分别失败5项/2项，修复后应转通过。

## 版本与范围

本轮从桌面配置仓库重新查询latest=0.11.30，dist.integrity与实施轮一致；桌面声明/Yarn锁0.11.30、实际安装0.11.17、历史pnpm0.2.78。复读发布版随包L0/数据指南/MIGRATIONS，核对s:fontWeight、快照和实体数据契约及受影响的本地转换实现，版本产物指纹沿用并复核[version-verification.json](version-verification.json)。未升级桌面、未新增最新版运行验收、真机/iOS或在线协同验收。正式42块及13/28/1/0统计保持，独立JSON路径的本轮缺陷已同步到适配表。
