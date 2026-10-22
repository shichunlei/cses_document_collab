# 协同历史审查问题修复

日期：2026-10-22。按[审查](review.md)的 R1、R2、R3、R4、R5 顺序完成修复，先处理两项 P1。保留原协同协议、SQLite 本地草稿、纯内存离线编辑和现有块能力。没有提交或推送，也没有修改其他会话的今日导向业务迁移。

## 修复与回归对应

| 问题 | 实现与结果 | 回归依据 |
|---|---|---|
| R1 / P1：空段落首次输入丢失 | Legacy 空/新增文字根在候选 UndoManager 订阅前注册。正文 snapshot 有变化却没有捕获组时，在 SQLite 写入前返回 `HISTORY_CAPTURE_INCOMPLETE`，不返回未安装的成功更新。 | Rust 覆盖既有空段落、追加空段落后独立输入、重开和写入/COMMIT 失败重试，以及漏捕获保护；真实 FRB 控制器覆盖空段落落盘重开后的输入与撤销/重做。 |
| R2 / P1：恢复光标断开输入连接 | 本地事务暂停从 `editable` 拆出；原生历史模式的远端回放不发布中间旧路径/空选区，完成最新投影后一次恢复稳定书签。输入暂停保持已有连接，也保留用户已收起的键盘；真实权限/预览仍控制输入附着。 | 页面直接调用 undo、redo、远端更新，检查真实输入 client 持续存在且没有 `hide` / `clearClient`；另三项在主动收起后验证正文/光标恢复而没有 `setClient` / `show`；表格单元格走真实平台输入、撤销和重做，正文、光标和连接共同断言。 |
| R3 / P2：表格删除撤销后重做自冲突 | 消失节点取删除前的可见指纹，新增可达节点取新增后的可见指纹；反向组保留原保护值，不把后到远端贡献纳入允许删除内容。 | 删行、删列及整表反复 undo/redo；列宽和网格恢复；其他存活行远端编辑可保留，待删除子树的远端新增贡献仍拒绝，正文/两栈/SQLite 不变。 |
| R4 / P2：普通投影误触发永久撤权 | 投影和历史只设置 `localTransactionsPaused`，不发出虚假的 editable=false。真实文档能力切换才同步权限；页面自己的预览/导入状态继续有效。 | 真实控制器的选人和会议选择在普通远端变化后仍可返回有效结果；真实撤权再授予也不会恢复旧面板提交资格。既有表格、Mermaid、公式和锁回归继续执行。 |
| R5 / P2：首次握手跳过编号修复 | 不再由投影伪只读阻断 onSync 的编号修复；无页面宿主在正式根首次可写时同步真实能力。系统修复不进入个人历史。 | 独立 Yjs 缺 order 夹具验证实际页面首次握手及无页面宿主首次握手；预览重握手仍保留缺号且原生状态向量与接收数据一致，不产生本地编号写入。 |

Rust 改动位于 [document_history.rs](../../../packages/cses_document_collab/rust/src/api/document_history.rs) 及两个内部调用点。Flutter 控制器在 [collab_controller.dart](../../../packages/cses_document_collab/lib/src/controller/collab_controller.dart)，投影选择策略在 [AppFlowy 适配器](../../../packages/cses_document_collab/lib/src/editor/appflowy_block_editor_adapter.dart)。没有修改 FRB 公共声明、生成物、依赖或 Yrs 检查点扩展。

## 输入暂停、权限与资源边界

- `EditorState.localTransactionsPaused` 由原生控制器拥有，默认 false；暂停不改变权限、焦点、选区和输入连接。`canApplyTransaction` 同时检查实际编辑权限、暂停与已有块事务策略；可信远端投影可以更新只读页面，但已销毁状态一律拒绝。
- 异步输入捕获权限/暂停 epoch；经历暂停再恢复或撤权再授予的旧输入不会继续写入。拒绝事务消费已有文本 compose 缓存，避免之后混入新输入。
- 最后复核又复现了主动收起键盘时仍在等待的输入回调会写入正文并重新连接的问题，见[修复前测试](fix-ime-close-before.dart.txt)和[失败日志](fix-ime-close-before.txt)。现用独立连接代次覆盖主动关闭、系统关闭、关闭再连，以及 interceptor/字符快捷键内部等待。旧回调不能改正文、重连或覆盖新连接；同一连接的普通内容刷新不使新输入失效。自定义异步快捷键自身产生的副作用仍由其实现者负责核对生命周期。
- 关闭会取消本服务的 debounce；不同服务使用独立 key。Widget 释放自有输入连接，仅释放自建 FocusNode。迟到失败不能恢复已关闭缓存。
- 关闭键盘后的真实页面补充复核还发现选区恢复会重新 `attach/show`，见[修复前最小复现](fix-closed-keyboard-before.dart.txt)与[失败日志](fix-closed-keyboard-before.txt)。暂停期间有效选区只刷新已有连接；没有连接时保留关闭状态，正文和光标仍正常恢复。用户再次主动点击正文后仍可建立输入连接。
- 原生历史下，回放通过 `withUpdateSelection:false` 延后中间选区通知；未绑定外部历史的独立适配器仍保留原路径历史失效策略。页面预览、锁、目标删除/替换及真实权限撤销的原有保护保留。

新增 **40 项**正式回归：Rust 9 项、协同包 15 项、AppFlowy 16 项，分别见 [Rust 测试](../../../packages/cses_document_collab/rust/src/api/document_history_tests.rs)、[真实 FRB/页面测试](../../../packages/cses_document_collab/test/native_history_review_regression_test.dart)、[输入暂停与关闭测试](../../../packages/appflowy_editor/test/legacy/local_transaction_pause_test.dart)。

编号夹具由随仓库的 [Yjs 生成器](../../../packages/cses_document_collab/tool/generate_native_history_review_fixture.mjs)生成，固定独立 client ID，输入基础夹具、Yjs 版本和字节哈希均记录在 [JSON](../../../packages/cses_document_collab/rust/tests/fixtures/native-history-review.json)，重复生成字节一致。运行回归不依赖临时审查脚本。

## 最终验证

完整命令、退出码、源码及证据哈希见 [fix-validation.json](fix-validation.json)。

| 范围 | 结果 |
|---|---|
| Rust 主 crate | `cargo fmt --check`、`cargo check --offline --features history-prototype`、本机原生构建通过；含 prototype 的全量测试 **191 通过，0 失败/忽略**。[测试日志](fix-rust-tests.txt) |
| 协同包全量 | **1627 通过，0 失败/跳过**，显式启用手机初始化增量与桌面/latest Yjs 互通用例。[日志](fix-cses-tests.txt) |
| AppFlowy 全量 | **937 通过，0 失败/跳过**；全包分析无问题。[测试](fix-appflowy-tests.txt)、[分析](fix-appflowy-analyze.txt) |
| 宿主全量 | **210 通过、1 失败、0 跳过**，指定本机动态库目录。最后一轮发现期间新增的日记剪贴板审查探针失败；此前没有该探针的 210 项全量通过。[最终精简日志](fix-host-tests.txt) |
| 格式、分析与差异 | 13 个本轮手写 Dart 文件格式核对通过；协同包及宿主目标分析无问题，`git diff --check` 通过。协同包全分析仍有触达外的 2 条既有 info；宿主全分析另有 4 条既有直接依赖声明 info，详见下文。 |
| 平台 | Android 调试 APK 构建通过，16 个实际参与 Android 编译的关联 Dart 文件与 kernel 中源码逐字节匹配，包含 3 ABI Rust 库；iOS arm64 真机、arm64/x86_64 模拟器原生库和 XCFramework 构建通过。[Android 产物](fix-android-artifact.json)、[iOS 原生产物](fix-ios-native-artifact.json) |

包/宿主数量反映本轮当前工作区，今日导向测试已由另一会话随业务迁到宿主；不能与第三阶段旧快照按包内数量直接比较为测试删减或失败。本轮保留该迁移并运行当前两层全量。

协同包既有 info 为 `collab_video_block.dart:265` 的 `unawaited_futures`、`collab_controller_native_test.dart:186` 的 `close_sinks`。宿主既有 info 为 `app.dart` 的 bot_toast、`cses_editor_media_upload_service.dart` 的 file_picker/mime、`markdown_file_picker.dart` 的 file_picker 直接依赖声明；其全分析输出包含前述包内 2 项，共 6 项。均不是本轮引入，未借机批量修改。相关目标分析通过，[包全分析](fix-cses-analyze-all.txt)和[宿主全分析](fix-host-analyze-all.txt)按实际非零退出码保存。

早期表格平台输入测试漏带 NonDelta 协议的前置占位字符，导致预期光标 2、实际 1；已改为读取真实平台 editingState 并在其选区输入，保留编辑器光标必须为 2 的断言。原 [58 通过/1 失败日志](fix-native-targets-before-payload-correction.txt)保留，扩展后的正式 15 项及全量均重新通过。首次格式核对发现 4 个触达 IME 文件尚未采用完整标准格式，随后按既有 80 列完成格式化；[原结果](fix-appflowy-format-initial.txt)不重新标为通过。受限 SDK 启动问题不当作功能测试结果。

最终宿主测试的一次启动与 Android 打包共享缓存发生冲突，尚未进入测试就缺少 `native_assets.json`，见[原日志](fix-host-cache-startup-failure.txt)；打包完成后单独重跑得到210通过/1失败，不以这次工具启动失败代替功能测试结论，也没有清理工作区或调整源码来绕过。

最终新增失败是另一会话在验证期间加入的 `test/daily_guidance/review_clipboard_probe_test.dart`，用例 `cut a mention then paste must round-trip the selected content`：纯内存日记剪切含人员引用的段落后，`LocalJournalController.pasteFromClipboard` 第149行抛出“粘贴内容超出日记支持的格式或容量”。它没有挂载输入连接，也未使用原生历史；拒绝发生在宿主自己的粘贴格式校验中。本轮没有修改日记代码、删除该探针或放宽断言。宿主最终全量不能标为全绿，此问题留给所属日记工作处理；本轮5项问题的正式回归及两包/Rust全量均通过。探针源哈希、最终失败和此前210项通过快照均保存在验证清单。

## 上游核对与验收限制

通过桌面配置仓库重新查询 latest **0.11.28**；桌面声明/Yarn 锁 **0.11.24**、安装 **0.11.17**、历史 pnpm **0.2.78**。已复核随包技能、MIGRATIONS、历史/选区及受影响实现；缓存发布产物与最新 registry 元数据 SHA-512 一致，见[版本证据](fix-blockcraft-version.json)。本轮不升级依赖，41 块及 13/14/1/13 统计不变；.28 动画及原兼容差异仍待同步。

本轮未操作物理手机、连接真实服务器或验收真实桌面/手机在线双端；iOS 只验证原生构建，未重新完成整个 App 的 SwiftPM 构建。输入连接测试使用真实 Flutter 文本输入客户端和 Widget 平台通道，不能替代具体手机输入法验收。跨事务 IME 合组、跨启动个人历史、多单元格/对象选区、长文视口恢复以及全 Doc 候选复制的性能/内存仍在后续范围。上游 vendored Yrs 的既有 2 处格式差异及警告保持，不宣称其全包格式门禁通过。

提交阶段首次将 vendored Yrs 纳入暂存树，`git diff --cached --check` 显示3个上游原文件的17处尾空白；其哈希与上游来源一致，按来源保留，没有为通过检查清理上游代码。手写源码、测试和说明文档无该问题；原始测试/分析/差异日志的行末空白与末尾空行按字节保留，相关文件哈希及单独检查结果见[提交核对](commit-check.json)及[原输出](commit-vendor-whitespace.txt)。前文差异检查是修复完成时尚未暂存新 vendor 的历史结果。
