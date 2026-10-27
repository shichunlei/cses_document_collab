# image_composer 分层分析

本报告保留分析阶段的结论与验证范围；随后实施的迁移见 [migration.md](migration.md)。源码链接已指向迁移后的对应实现。

日期：2026-10-24。范围：当前工作区的 `cses_document_collab` 制图/本地编辑入口、宿主调用及公开编辑器能力。只做架构分析，不实施迁移，不改变块支持范围。

## 结论

当前 `image_composer` 更适合归宿主的功能/业务装配层。建议将页面、路由入口、模板及组合会话迁至宿主 `example/lib/src/image_composer/`，通用编辑、预览渲染、输入、历史、配置和协同能力继续留在 `cses_document_collab`。如果它仅用于展示编辑器，则放宿主 `demo/` 或包的示例中。

这不是由目录名或是否联网决定的。共享包可以提供 UI 和本地编辑能力；当前 composer 的主要职责却是决定一个具体功能怎样打开、展示、切换模板和退出，属于对底层能力的使用。其依赖方向目前是干净的：没有直接导入 Demo、宿主账号、业务 HTTP 或日记上下文，宿主服务通过 `CollabHostServices` 显式注入。建议迁出的原因是职责归属，而非已经存在反向依赖。

`packages/` 本身允许承载业务包。如果将来多个应用确实复用完整制图产品，可以单独建立上层功能包并依赖编辑器包。当前仓库没有这样的复用证据，无需为这一入口新建包。

## 源码依据

| 对象 | 当前职责和依据 | 建议归属 |
|---|---|---|
| `showCollabImageComposer` | 创建组合控制器、选择默认模板、推入 `MaterialPageRoute`，等待退场后关闭资源；返回 `Future<void>`，不保存正文或返回图片。[源码](../../../example/lib/src/image_composer/show_image_composer.dart) | 宿主导航与功能入口 |
| `ImageComposerPage` | 固定“本地编辑器”标题、撤销/重做和预览入口，600 逻辑像素宽度上限、渐变背景/白卡、模板选择器和页面错误提示。[源码](../../../example/lib/src/image_composer/image_composer_page.dart) | 宿主功能页面 |
| `ImageComposerController` | 组合 `LocalEditorController`，维护模板索引、独立预览快照及正文/预览的关闭顺序；没有新的编辑或协同协议。[源码](../../../example/lib/src/image_composer/image_composer_controller.dart) | 随页面迁出的功能会话编排 |
| `CollabImageTemplate` 与 `collabImageTemplates` | 约束背景色、边距和圆角，并内置“紫光/暖阳/晴空/薄荷/简约”五个模板。仓库内仅 composer 及其测试消费。[源码](../../../example/lib/src/image_composer/image_composer_template.dart) | 当前一起迁宿主；日后有独立共享场景再提炼通用样式模型 |
| `LocalEditorView` | `DocumentEditorView` 的薄包装，附加 `image-composer-editor` Key；当前没有导出。[源码](../../../lib/src/editor/document_editor_view.dart) | 页面直接组合公开视图即可；若保留包装，随功能迁出 |
| `LocalEditorController`、`DocumentEditorController`、`DocumentEditorView`、配置及服务端口 | 提供不依赖该页面的正文事务、输入/历史、能力限制、通用渲染及宿主注入；已经通过包入口公开 | 留共享包 |

名称也已经落后于行为：当前实现不生成 PNG，不做编码/截图导出，关闭不保存正文，实质是本地编辑和模板预览。未来命名应依据产品用途决定；不能仅因 `image_composer` 名称就假定它包含图片合成基础设施。

## 调用方及迁出可行性

- 仓库生产调用只有宿主 [collab_demo_page.dart](../../../example/lib/src/demo/collab_demo_page.dart) 的 `_openOfflineImageComposer`。根 `test/`、`integration_test/` 未检出该入口调用；包内另有页面和离线能力测试。仓库搜索不能证明外部消费者不存在。
- [包公开入口](../../../lib/cses_document_collab.dart) 已导出 `LocalEditorController`、`DocumentEditorController`、`EditorCommandContext`、`EditorConfiguration`、`DocumentEditorView` 和 `CollabHostServices`。这些接口足以复现当前组合，不需要宿主导入包的 `src/`。
- 宿主 [pubspec.yaml](../../../example/pubspec.yaml) 已直接声明 `cses_document_collab`、`appflowy_editor` 和 `lucide_icons_flutter`。当前没有必须扩展包 API 才能搬迁的硬性缺口；尤其不应仅为搬迁而公开 `LocalEditorView`。
- 今日导向没有依赖 composer。[LocalJournalController](../../../example/lib/src/daily_guidance/local_journal_controller.dart) 直接创建公开编辑器会话，[JournalSurface](../../../example/lib/src/daily_guidance/journal_surface.dart) 用公开视图注入业务外观，[LocalJournalPage](../../../example/lib/src/daily_guidance/local_journal_page.dart) 组合独立预览。它是现成的同类分层范例；composer 与其并列，不必合并进日记模块。
- 当前预览通过 AppFlowy `Document.toJson/fromJson` 深拷贝内存正文，不是桌面 BlockCraft JSON 交换。迁出无需引入日记转换器或日记存储模型。

## 最小迁移边界（尚未实施）

1. 将 `image_composer/` 三个文件、模板模型及内置模板迁至宿主功能目录，保留现有交互和资源所有权。正文直接使用公开 `DocumentEditorView`，继续共用包内工具栏、选区、输入及历史，不复制编辑实现。
2. 调整 Demo 调用。移除包的制图路由和模板导出，同步包级说明及使用示例；这是公开 API 调整，实际实施时需检查已知包外消费者。如果存在不能同步升级的消费者，再设计弃用期，不能让共享包通过兼容转发反向依赖宿主。
3. 保留结束输入、选区恢复、预览旧视图卸载后关闭、路由完整退场后关闭正文的顺序。显式注入的宿主服务继续借用；迟到回调不得操作已关闭会话。
4. 按测试职责拆分，不按文件名整批移动。页面/模板/路由测试迁宿主；`image_composer_operations_test.dart` 实际验证公开本地编辑器和工具栏，应留包内。原生隔离测试继续在包内覆盖通用本地会话，宿主另测页面组合，避免包测试反向导入宿主。
5. 宿主测试不能延续包内测试对 `CollabBlockLocks`、FRB 等 `src/` 的直接导入；改为公开行为验证，内部断言留包内。`offline_all_blocks_test.dart` 中借 composer 路由装配的通用能力测试应改成包内测试夹具。
6. 独立只读快照的创建在 composer 和日记中均有使用。可以后续评估是否提炼通用快照能力；仅提炼文档克隆及所有权契约，不带模板、路由或功能状态。它不是本次迁出的前置条件。

实际迁移后应在共享包与宿主分别运行目标分析及测试，检索旧路由/模板出口、旧路径和跨包内部导入，检查 `git diff --check`。纯 Dart 装配搬迁无需顺带修改 Rust 或生成桥接文件。

## BlockCraft 版本核对

本轮使用桌面 `/Users/shichunlei/workspace/cses-client` 配置的仓库查询，实时 `latest=0.11.30`；根声明/Yarn 锁定为 `0.11.28`，实际安装为 `0.11.21`，历史 pnpm 锁为 `0.2.78`。首次请求因代理 EPERM 降级到缓存，缓存的 `0.11.27` 不作为最新版本结论；随后隔离缓存的联网查询成功。

随包技能、迁移说明及发布实现核对证据见 [version-check.json](version-check.json)。最新版 `ai-skills/blockcraft-app.md` 的位图导出说明也将应用专属截图路径归宿主；它对未来图片导出归属有参考意义，当前 composer 本身并没有导出能力。本轮不升级桌面或移动依赖，不重新宣称完整 `0.11.30` 兼容。块、行内对象、选区/菜单、剪贴板、输入、历史、协同及设备运行的既有待同步/待验收项保持；迁出结论来自当前 Dart 的职责和公开边界，不取决于上游版本一致。

## 本轮验证与限制

- 通过只读源码、公开出口、直接依赖和调用方检索形成结论；未运行 Flutter 测试、构建、真机或在线双端验收，也不复用历史测试结果宣称本轮运行通过。
- 未修改 Dart、依赖、公开 API 或运行行为。开始时 `image_composer_page.dart` 已有去掉 `createState` 显式返回类型的工作区改动，保持原样。
- 新增本报告/版本证据，并同步归档索引与主表版本跟踪；不调整块状态和适配统计。版本 JSON 可解析，报告12个相对链接及2处索引引用目标存在；`git diff --check` 通过，新增证据文件无尾部空白。
