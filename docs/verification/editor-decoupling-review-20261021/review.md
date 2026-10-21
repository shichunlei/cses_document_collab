# 编辑器与同步解耦后代码审查

后续复核更正：R7为误报，原事务已推进光标，实际为旧测试的插入位置与期望矛盾。其余六项实现缺陷已修复，详情见[修复记录](/System/Volumes/Data/workspace/mobile-collab-demo/docs/verification/editor-decoupling-fixes-20261021/report.md)。以下测试数量保留审查时快照。

日期：2026-10-21。基于当前整个工作区，包含已提交代码、已有未提交修改及新增文件，不以 Git diff 为审查边界。本轮只审查，没有修复生产代码；临时复现保留为 `.dart.txt`，避免把有意失败的审查用例加入正常测试发现范围。

## 结论与覆盖边界

编辑会话与同步的运行时职责已分开，本地会话可独立创建、输入、撤销和预览，不必启动 Rust、SQLite 或网关。当前尚不能认为迁移已完成：两项 P1 涉及跨文档串用和容器内容丢失；初轮另记录五项 P2，后续撤销 R7 误报，最终为四项实现 P2 和一项测试设置错误；包含既有控制器及底层编辑器问题。

全量静态检查和测试覆盖宿主、`cses_document_collab`、本地 `appflowy_editor` fork 及 Rust crate；人工沿完整模块的公共入口、数据流、事务、历史、权限、异步关闭及块/媒体资源边界检查，包含未修改代码。并非逐行人工审阅约九万行手写代码，也不构成所有平台、所有块组合的穷尽证明。生成 FRB 文件及第三方压缩运行时未逐行手审。

源文件哈希及清单见 [source-inventory.json](source-inventory.json)。其中宿主 lib 为 19 个 Dart 文件；协同包 lib 为 160 个 Dart 文件（6 个生成文件）；AppFlowy lib 为 381 个 Dart 文件（识别到 1 个生成文件）；Rust src 为 8 个文件（1 个 FRB 生成文件）。清单也包含测试、模型、原生配置及工具入口，不仅包含解耦改动。

## 已确认缺陷

### R1 · P1：初始化失败后的重试可发送另一文档的正文

定位：[CollabController.retry](/System/Volumes/Data/workspace/mobile-collab-demo/packages/cses_document_collab/lib/src/controller/collab_controller.dart:303)，关联初始化的 252、269–270 行及 `_startSession` 中直接访问全局 Rust 文档的回调。

`_initialized` 在会话注册前设为 true。注册失败后 catch 关闭并释放唯一原生引擎，却未使控制器失效或重建其初始化状态。`retry()` 只看 initialized/busy，不核对 `CollabRuntime.owns(this)`，直接创建新会话；状态向量及正文增量回调操作的是当前进程的全局文档。

复现：A 为可编辑正式文档，令宿主 register 抛错；B 随后接管原生引擎，在独立临时 SQLite 文档输入 `PRIVATE_NEXT_OWNER`；恢复网关并调用 A.retry，再向 A 派发空 collabSync。A 发出的 collabUpdate 与此时 B 的 encodeDocumentDiff 字节完全一致。没有连接实际服务器，全部消息由假网关记录。

建议：统一初始化失败后的状态/所有权策略；重试必须恢复所属文档后才能注册会话，所有原生回调同时校验所有者及会话世代。仅在 retry 顶部 return 能止住此入口，但不足以解决失败控制器的恢复契约。

证据：[原生复现日志](native-probe.txt)、[可恢复的复现源码](review_native_ownership_probe_test.dart.txt)。

### R2 · P1：本地 convert 对容器整体替换，丢失子树

定位：[LocalEditorController.convert](/System/Volumes/Data/workspace/mobile-collab-demo/packages/cses_document_collab/lib/src/editor/local_editor_controller.dart:354)。

公开命令允许任意已启用类型；对当前选中节点仅复制 attributes，构造不含 children 的 replacement，然后删除整个原节点。默认启用表格等容器后，该命令不再只面对文字叶子。

复现：本地创建表格，在单元格写入 `KEEP`，将选区设在表格节点并调用 `convert('paragraph')`；执行后的文档已无 `KEEP`，只有带遗留表格属性的空段落。此复现是公开控制器命令路径，未声称已通过手机菜单触发。撤销可能恢复内容，但不能替代写入前的保护。

建议：按块类型定义可转换集合；仅对可编辑文字叶子执行原位转换，容器应明确拒绝或使用保留子内容的专用语义，转换时清理来源类型属性。

证据：[本地复现日志](probes.txt)、[复现源码](review_decoupling_probe_test.dart.txt)。

### R3 · P2：权限注册失败污染串行队列，关闭跳过订阅清理

定位：[setEditable](/System/Volumes/Data/workspace/mobile-collab-demo/packages/cses_document_collab/lib/src/controller/collab_controller.dart:290)，关联 [shutdown](/System/Volumes/Data/workspace/mobile-collab-demo/packages/cses_document_collab/lib/src/controller/collab_controller.dart:788)。

`_accessTransition.then` 只链接成功回调；一轮 register 失败后，后续权限切换都继承旧的 rejected Future，根本不再注册。关闭先等待这个失败 Future，进入 catch 后跳过 `_releaseSession()`，保留部分启动会话的网关订阅。

复现：初始化成功，下一轮 setEditable(false) 注册失败，恢复网关后 setEditable(true)，最后 close。期望恢复成功、注册共 3 次、关闭无监听；实测恢复失败、仅 2 次注册、关闭后 `events.hasListener == true`。这是此前审查指出、目前仍存在的问题，本轮在新原生库上重新复现。

建议：让内部串行队列可恢复，同时把每轮错误交给调用方；部分启动失败立即释放；关闭不应因为前置任务失败而跳过必要清理。

证据：[原生复现日志](native-probe.txt)、[复现源码](review_native_ownership_probe_test.dart.txt)。

### R4 · P2：本地多行粘贴破坏代码块语义

定位：[LocalEditorController.pasteText](/System/Volumes/Data/workspace/mobile-collab-demo/packages/cses_document_collab/lib/src/editor/local_editor_controller.dart:503)。

所有块统一按换行拆节点，仅首行沿用原类型，后续强制创建 paragraph；这与代码块回车应在源码 Delta 内保留换行的规则不一致。本地公开粘贴及其接管的纯文本快捷键会经过该路径。

复现：空块转 code，粘贴 `one\ntwo`；结果为 code(one) + paragraph(two)，而非一个 code(one\ntwo)。代码后半部分离开代码块，且普通段落还复制了代码外观属性。

建议：在共用块命令层按当前块语义粘贴，代码块保留换行；不要让本地数据装配层重新实现一套与原编辑器不同的编辑规则。

证据：[本地复现日志](probes.txt)、[复现源码](review_decoupling_probe_test.dart.txt)。

### R5 · P2：关闭对齐能力会连带禁用标题转换

定位：[rich transaction guard](/System/Volumes/Data/workspace/mobile-collab-demo/packages/cses_document_collab/lib/src/editor/local_editor_controller.dart:157)。

富内容校验要求节点的每个显式 align 都在配置列表中。共用块转换会写入默认 left，因此 alignments: [] 不仅隐藏布局操作，还令普通标题/代码等转换事务被静默拒绝。

复现：以 `EditorConfiguration(alignments: const [])` 创建本地会话，通过现有 `applyBlockShortcut(..., 'heading', headingLevel: 2)` 转换；返回后节点仍是 paragraph。没有抛错，界面表现为菜单点击无效。

建议：区分基础默认值与用户主动写入的布局能力，明确配置控制入口还是允许的内容状态，并让菜单和事务校验采用相同语义。

证据：[本地复现日志](probes.txt)、[复现源码](review_decoupling_probe_test.dart.txt)。

### R6 · P2：底层段落工厂清空继承的 RTL 方向

定位：[paragraphNode](/System/Volumes/Data/workspace/mobile-collab-demo/packages/appflowy_editor/lib/src/editor/block_component/paragraph_block_component/paragraph_block_component.dart:44)。

构造 attributes 时先展开调用方 attributes，再无条件写入可选 textDirection；未显式传该参数时，用 null 覆盖了已提供的方向。`insertNewLine` 恰好通过 attributes 传递旧段落方向，因此 RTL 段落换行后丢失方向。

现有 `test/new/command/text_commands_test.dart` 的 `insert new line preserve direction` 全量及单独执行均失败：期望 rtl，实际 null。该实现位于本地 fork 的既有代码，不属于本次解耦的新增代码。

建议：显式参数为空时保留 attributes 中的方向，核对工厂与所有调用方对 null 的一致契约。

证据：[单独复跑日志](rtl.txt)。

### R7 · 后续复核撤销：实现正常，旧测试的插入位置与期望矛盾

原审查漏查了 Transaction.insertTextDelta 会自动设置 afterSelection。独立回归在原实现上通过：中间插入后光标推进，连续粘贴保留后缀、格式和历史，因此不能把旧失败归因于该实现。

旧 multiple times 用例显式把光标设在第10位，却使用末尾追加的期望。后续修正其测试位置为当前段落末尾，并新增中间连续插入回归；pasteHTML生产实现和公开签名保持。证据见[原实现新回归日志](/System/Volumes/Data/workspace/mobile-collab-demo/docs/verification/editor-decoupling-fixes-20261021/legacy-paste-original.txt)和[修复记录](/System/Volumes/Data/workspace/mobile-collab-demo/docs/verification/editor-decoupling-fixes-20261021/report.md)。此前appflowy-paste.log只证明旧测试失败，不证明光标实现缺陷。

## 现有结构与依赖判断

```text
宿主：身份 / 物理连接 / 上传 / 业务详情
  ├─ 离线页面 → ImageComposerController
  │              ├─ LocalEditorController → DocumentEditorController
  │              └─ 独立 DocumentEditorController 预览快照
  └─ 协同页面 → CollabController
                 ├─ DocumentEditorController
                 ├─ AppFlowyBlockEditorAdapter → EditorSynchronizationBinding
                 └─ CsesDocCollaborationSession → 借用网关
                          ↕ Rust 单文档引擎 / SQLite / Yrs

两种装配共用 DocumentEditorView、块构建器、菜单及选区操作。
EditorCommandContext 按 EditorState 注入配置、业务端口和本地粘贴。
```

- 所有权基本合理：编辑会话拥有 EditorState/typing/事务订阅；视图借用状态；预览拥有独立快照；协同控制器拥有适配器/文档会话，仅借用宿主连接。重建当前 Rust dylib 后，18 项原生关联回归通过，包含本地编辑/预览不改变活动原生文档及宿主服务的隔离检查。
- 依赖还未完全收敛：DocumentEditorView 和不少共用编辑命令仍从大型 AppFlowyBlockEditorAdapter 取得节点常量、模型及辅助函数。建议将这些纯编辑定义提到 editor/model 或明确的编辑模块，适配器仅负责投影、身份与同步历史；目前属于维护边界问题，不能直接断言本地会话会因此启动 FFI。
- 公共颜色、表情和媒体进度组件仍导入 native/collab_runtime 并调用全局 CollabDiagnostics。异常会按当时活动协同宿主上报，而非天然归属于当前本地编辑实例。建议由展示作用域/显式回调传入错误端口；保留 legacy 回退仅供明确的兼容装配。此项记录为结构风险，没有计入六项已复现的实现缺陷（R7后续撤销）。
- 本地控制器同时承担能力校验与 format/convert/paste 算法，富内容默认开启后与共用命令产生规则分叉，R2/R4/R5 已体现这一点。建议本地层只提供事务策略、容量及会话装配，编辑命令共用；能力清单和实际块语义应有同一个来源。
- 不建议此时再次大规模迁移目录或重写所有块。先修复所有权/内容保护及失败清理，再逐步收敛命令和纯模型依赖，并补边界测试。

## 全量验证结果

数量只统计可见实际测试，排除 reporter 的加载、setUp/tearDown 等隐藏事件。原始 reporter 路径、失败名和错误摘要见 [validation.json](validation.json)。

| 范围 | 结果 |
|---|---|
| 协同包全量 Flutter 测试 | 1534 通过，45 失败；其中 43 项名称与 10 月 20 日既有失败清单完全重合，2 项为标题图标变更后仍查找 Text(H4)/Text(H1) 的过期断言。不能把旧失败视为行为正确或门禁通过。 |
| 宿主全量 Flutter 测试 | 58 通过。 |
| AppFlowy fork 全量测试 | 913 通过，2 失败；独立复跑仍失败，见 R6/R7。 |
| 重建原生库后的关联回归 | 18 通过；覆盖 8 个测试文件。 |
| 审查新增安全期望复现 | 5 个用例按预期揭示缺陷并失败：本地 3 个、原生 2 个；不是通过的回归测试，未留下于正常 test 目录。 |
| Rust | cargo test 102 通过；cargo build、cargo check、cargo fmt --check 通过。 |
| 协同包分析 | 全包 1 条既有 close_sinks 信息，无 error/warning；两份复现源码单独分析无问题。 |
| AppFlowy 分析 | 无问题。 |
| 宿主分析 | lib/test 定向检查无 error/warning，有 8 条未直接声明依赖的信息；根目录全量额外扫到已有 build 缓存中的 1 error/1 warning，以及包测试的 1 条信息。不能宣称根全量 analyze 通过；未为消除提示清理 build 或改无关依赖。 |
| 原生工具脚本 | build_rust_ios.sh、verify_portable_package.sh 的 bash -n 通过；没有重新执行完整异地消费者构建。 |

标题断言位于 [image_composer_operations_test.dart:185](/System/Volumes/Data/workspace/mobile-collab-demo/packages/cses_document_collab/test/image_composer_operations_test.dart:185) 和 [image_composer_operations_test.dart:301](/System/Volumes/Data/workspace/mobile-collab-demo/packages/cses_document_collab/test/image_composer_operations_test.dart:301)。应改为稳定 Key、实际 Icon 或可访问语义断言，并继续检查对应转换行为。本轮没有改这些测试。

本轮未重新运行 Android/iOS 构建、手机手势、真实联网协同、服务端 ACK 或大文档性能测量。已有真机记录不是本轮新增覆盖。前述全量测试失败阻止给出“全套回归通过”的结论。

## 版本核对

在桌面项目配置仓库实时查询 `@ccc/blockcraft` 的 latest 为 **0.11.23**；根声明与 Yarn 锁定 **0.11.24**，实际安装 **0.11.17**，历史 pnpm 锁 **0.2.78**。读取/复核对应发布产物技能、迁移与相关实现；本轮没有升级桌面或移动依赖。此前已确认 .24 指定版本元数据 404，但锁定 tarball 可取得且校验一致，这不改变 latest 标签结论。

本轮核对侧重事务、命令、输入、历史及协同边界；.24 只读链接导航等原有差异仍待同步或验收。不把版本标签记录视为全部 Schema/块兼容通过。正式块清单仍为 41 种，13 已适配 / 14 部分支持 / 1 结构支持 / 13 未适配。

## 复现与修复顺序

两份 `.dart.txt` 为完整测试源码。需要复跑时，将其临时复制回协同包 test 下同名 `.dart`；在包目录运行 `flutter test --no-pub test/review_decoupling_probe_test.dart` 和 `flutter test --no-pub test/review_native_ownership_probe_test.dart`。后者使用包内当前 debug 原生库，先在 rust 目录 cargo build。只使用临时 SQLite 和假网关，不发送真实网络消息；复跑结束移除临时 test 文件。

建议先 R1 → R2 → R3，再修复 R4/R5 并统一共用命令；R6 在 fork 内修复并验证消费者；R7纠正测试设置且验证原实现；同步修复两项图标旧断言，逐项确认其余 43 项失败，最后再验收手机与真实协同。
