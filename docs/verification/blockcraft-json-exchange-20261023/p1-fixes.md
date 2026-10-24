# 两项 P1 修复与双向完整性验证

日期：2026-10-23。承接[再次审查](review-2.md)的RR1/RR2，在既有六项修复基础上继续完成，不改变历史审查失败记录。本轮未提交或推送，保留无关工作区改动。

## 结果

两项P1均已修复，新增22项正式回归（共享包13、宿主9）。共享包全量1712项、今日导向宿主190项全部通过，无跳过；包测试显式传入桌面目录，包含实际FRB/SQLite、段落历史及桌面包互通测试。两个受影响层的目标静态分析无问题，Android调试构建通过，当前APK精确包含19份相关生产源。

| 问题 | 最终行为 | 验证范围 |
|---|---|---|
| RR1：Tab真实嵌套导致导出漏掉待办 | 列表Tab/Shift+Tab使用平面depth；上限仍消费事件；导入日记禁用原生结构缩进快捷键。depth同时更新原生层级和段落投影，撤销恢复原包装。文字叶块携带真实子块时，编码器抛FormatException，宿主事务整次拒绝。 | 待办/无序/有序列表的真实注册命令、上限/只读/表格导航；生产JournalSurface在栏目及高亮内验证；直接嵌套和混合选区的旧原生命令均被原子拒绝；带格式/人员提及/勾选状态及ID经过往返、历史和真实文件重开仍一致。 |
| RR2：空标题回车转正文丢业务和身份 | 回车和菜单共用同一属性保留函数，保留宿主显式业务键、桌面身份/独立属性/元数据/扩展字段及块背景；正文默认样式按原规则重置。 | help/pilot/task × 空H2/空引用六组真实宿主用例；包内额外覆盖引用same/body、撤销/重做及JSON恢复，非空标题在段尾新增正文仍分配新身份且不复制业务。 |

## 实现范围

- `editor_block_conversion.dart`集中读取原位转换应延续的字段；`editor_shortcut_toolbar.dart`和`collab_paragraph_editing.dart`共用，避免两个入口的保留规则分叉。不复制原始块JSON。
- `collab_paragraph_indent.dart`先识别获准的平面列表，使用既有列表事务；达到6级仍拦住标准结构缩进回退，表格导航继续交给表格命令。`collab_list_editing.dart`在同一事务更新两个深度字段，并保存原始包装用于Undo。
- `EditorConfiguration.withHost`新增可选structuralIndentation覆盖，null保持原值，默认document配置不变；导入的今日导向显式设false，正常平面缩进保持可用。
- `BlockCraftJsonCodec.encodeBlock`在编码前检查文字叶块的真实后代，不再成功返回删掉后代的快照；既有宿主预检复用该校验，拒绝时正文和历史都不变。

## 回归与双向转换

[共享包正式回归](../../../packages/cses_document_collab/test/blockcraft_json_integrity_test.dart)13项，包括三类列表Tab/Shift+Tab、容量/只读、非法树拒绝、三种空标题/引用回车、正常新增身份及表格命令边界。

[宿主正式回归](../../../test/daily_guidance/journal_blockcraft_integrity_test.dart)9项。保存/重开使用生产FileJournalStore和独占临时目录，实际执行后台编解码、flush和原子文件替换；源稿与反向导入稿分属不同文件，不依赖内存Store替身。

六组业务用例验证流程为：桌面JSON → 宿主稿 → 原位Enter → Undo/Redo → 桌面JSON → 独立文件反向导入并重开 → 原稿flush/关闭/重开。比较完整children，包含业务元数据、稳定ID及独立props；根级audit也单独验证。自动更新时间不作为正文相等条件。

两组Tab页面用例从实际JournalSurface装配的AppFlowyEditor取得注册命令，确认indent/outdent原生回退已过滤；对栏目内和高亮内的待办执行Tab、Undo/Redo、Shift+Tab和再次Undo后，验证depth=1、checked=true及原身份，并执行相同文件交换链。待办富文本包含加粗、22号字和原生人员提及，完整Delta在多次转换中相等。

三个生成示例通过桌面实际安装0.11.17的SchemaManager、native2YBlock、Yjs与BlockModelGraph装载，并由真正的BlockCraftDoc.exportSnapshot再次导出；深比较与手机导出完全一致。脚本为[verify-p1-fixed-exchange.mjs](verify-p1-fixed-exchange.mjs)，结果为[桌面模型验证](p1-fixes-desktop-model-validation.json)。

| 修复后示例 | 内容 |
|---|---|
| [p1-fixed-heading-help.json](p1-fixed-heading-help.json) | 空H2转正文后，entry-block身份、help业务和audit元数据保留，原字号按正文规则重置。 |
| [p1-fixed-quote-help.json](p1-fixed-quote-help.json) | 空引用转正文，保留同一业务条目和独立属性。 |
| [p1-fixed-todo-tab.json](p1-fixed-todo-tab.json) | root下两个同级块；todo保留checked=1、depth=1、加粗/字号/人员提及和audit，不生成文字块真实后代。 |

## 验证证据

- [p1-fixes-host-all-tests.txt](p1-fixes-host-all-tests.txt)：`flutter test --no-pub --dart-define=GENERATE_BLOCKCRAFT_EXAMPLES=true test/daily_guidance`，190通过。
- [p1-fixes-package-all-tests.txt](p1-fixes-package-all-tests.txt)：在共享包执行`flutter test --no-pub --dart-define=BOOTSTRAP_DESKTOP_ROOT=/System/Volumes/Data/workspace/cses-client --dart-define=BOOTSTRAP_PACKAGE_ROOT=/System/Volumes/Data/workspace/cses-client/node_modules/@ccc/blockcraft`，1712通过，无跳过；包括此前需显式桌面参数的互通测试。
- [宿主分析](p1-fixes-host-analyze.txt)、[共享包分析](p1-fixes-package-analyze.txt)：分别检查2/8个目标文件，无问题；相关消费者由宿主190项验证。
- [Android构建](p1-fixes-android-build.txt)、[19份当前源与APK精确匹配](p1-fixes-build-validation.json)：debug构建成功，未安装或新增设备验收。
- [p1-fixes-validation.json](p1-fixes-validation.json)：汇总测试、源文件与示例指纹、版本和限制。修改文件已格式化，`git diff --check`通过；新内部模块未新增跨包src导入或全局聚合入口。
- 本轮三个专用示例使用独立开关`GENERATE_BLOCKCRAFT_P1_EXAMPLES`；仅重新生成时执行`flutter test --no-pub --dart-define=GENERATE_BLOCKCRAFT_P1_EXAMPLES=true test/daily_guidance/journal_blockcraft_integrity_test.dart`。
- 证据维护说明：首次沿用旧通用生成开关跑全量，重新生成了三份上一轮示例（fixes-converted-journal、fixes-restored-mobile、fixed-journal-roundtrip）。旧校验记录/指纹保持原样，但旧字节未恢复；这些同名文件当前为本轮重生成值，不能用于证明上一轮原始产物。新旧指纹及归属见[p1-fixes-regenerated-artifacts.json](p1-fixes-regenerated-artifacts.json)。本轮正式结论使用p1-fixed-*专用示例。
- 保留中间日志：首次新共享文件导入常量错误导致编译失败，修正后目标回归发现列表depth未随实时层级更新，已补同一事务与逆补丁；另一次关联测试名写错，仅该文件加载失败。最终全量测试涵盖实际列表测试并全部通过，不将中间失败作为最终通过证据。

## 版本与限制

本轮从桌面配置仓库重新确认latest=0.11.30、integrity未变；桌面根声明/Yarn锁0.11.30，实际安装0.11.17，历史pnpm0.2.78，docs工作区自身声明^0.11.0-alpha。已核对对应随包技能、MIGRATIONS及受影响快照/段落/列表契约；安装版与最新发布产物指纹未变，详见[版本记录](p1-fixes-version-verification.json)。本任务未写桌面依赖。

0.11.30仍仅静态核对，模型运行使用实际安装0.11.17；本轮未新增真机、iOS或线上双端验收。既有上游组合内容域、图片gap、菜单输入/历史协同、高级对象工具和独立Vectra图正文待办保持。真实子块不能作为桌面文字叶块的结构输出，异常结构明确报错，源数据不静默降级；本轮不承诺修复历史异常草稿。正式42块与13已适配/28部分支持/1结构支持/0未适配统计不变。
