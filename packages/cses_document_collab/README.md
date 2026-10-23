# cses_document_collab

Flutter FFI 插件包，提供正式 BlockCraft 文档的原生编辑、Yrs 差量协同、Awareness、SQLite 恢复及移动端块渲染。Dart >=3.12、Flutter >=3.44；移动端支持 Android（最终宿主至少 API 24）和 iOS 14+。macOS/Linux 原生库仅用于测试，不声明桌面插件支持。

包的源代码与原生构建都在此目录内。包不依赖 demo、cses.saas、cses.common、登录接口或全局账号。依赖方向是宿主 → 本包 → AppFlowy/FRB/Yrs；Gateway 与上传服务由宿主实现。

## 接入

最终 App 的 pubspec 添加本包的 path 依赖。当前使用本项目 `packages/appflowy_editor` 下的 AppFlowy 6.2.0 fork，它包含 Flutter 3.44 输入适配和撤销修复；本包通过 `../appflowy_editor` 引用它。AppFlowy 的 `diff_match_patch`、`scroll_to_index` 直接使用 pub.dev 发布版本。迁移时应保留本包与 appflowy_editor 的同级目录结构；单独移动本包时，宿主需通过 dependency_overrides 指向可用的同一 fork。

```yaml
dependencies:
  cses_document_collab:
    path: packages/cses_document_collab
```

宿主代码只 import `package:cses_document_collab/cses_document_collab.dart`。以下函数返回的控制器由调用方持有，路由退出/账号切换前必须 `await controller.close()`：

```dart
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';

Future<CollabController> openDocument({
  required CsesCollabGateway gateway,
  required String documentId,
  required String websocketIdentity,
  required String companyId,
  required String userId,
  required String databasePath,
  required bool editable,
}) async {
  final controller = CollabController.cses(
    config: CollabDocumentConfig(
      documentId: documentId,
      serverIdentity: websocketIdentity,
      companyId: companyId,
      userId: userId,
      databasePath: databasePath,
      editable: editable,
    ),
    gateway: gateway,
    services: CollabHostServices(
      onError: (message, error, stack, tag) =>
          debugPrint('$tag: $message: $error\n$stack'),
    ),
  );
  try {
    await controller.initialize();
    return controller;
  } catch (_) {
    await controller.close();
    rethrow;
  }
}

Widget editor(CollabController controller) =>
    CollaborativeEditorPage(collab: controller);
```

`initialize()` 完成表示原生初始化、本地恢复和文档回调注册结束。`ConnectionStatus.online` 表示客户端完成差量交换；没有服务端保存 ACK，不能显示“已保存到服务器”。编辑页内部安装 AppFlowy 本地化代理；宿主只需标准 Flutter Material/Cupertino 本地化。

## 宿主契约

- Gateway 提供已完成 hello 的连接状态、按 pageId/docId/instance 注册 action 回调、立即发送结果及异步注销。恢复通知必须在恢复 Document subscribe 后发出；文档会话随后 join。离线发送返回 false。物理连接始终由宿主持有。
- `CollabDocumentConfig` 不含 cookie。`serverIdentity` 使用原完整 WS 地址，企业/用户/docId 与旧缓存保持一致；SQLite 路径由宿主选择。凭证轮换不改变缓存键。根 ID 与缓存键不能混用。
- Rust 是进程全局单 Doc。第二个独立控制器初始化抛 `COLLAB_DOCUMENT_IN_USE`，先等待旧控制器 close；多个视图可借用一个控制器。
- `setEditable(false)` 立即禁止本地写入，并串行重建只读会话。只读握手只发送空 V1 update，缓存中的未同步修改仍被保留；恢复授权后向量同步补传。模型只读约束同时生效，服务端仍需逐次鉴权。
- `resync()` 用于前台恢复，保留终止错误；`retry()` 是用户显式重试。控制器不创建或恢复物理连接。resetLocalCache 只清理当前分区，随后可调用 retry 重新 join。
- `CollabHostServices` 注入 ID 工厂、错误报告、可选 `CollabMentionDirectory` 和 `EditorMediaUploadService`。没有上传服务时只显示 URL 输入；上传实现持有宿主认证。现有接口使用 Dio CancelToken 表达取消。
- `localDraft` 是独立模式，保留旧 demo schema 和头部迁移；默认封面由宿主传入。正式模式不经过草稿初始化、不创建业务根/标题/封面。
- FRB、Rust 原始 API、EditorState 和内部块类型是包内实现，宿主使用公开控制器状态/命令及编辑页。不要从 src 导入。

## 正式空文档准备

宿主先通过业务HTTP创建文档记录，持久化返回的正式docId和稳定的operationId、paragraphId、createdAt，
等待旧控制器关闭，再调用公开的`DocumentBootstrapper.prepareBlank()`。该方法不创建视图或协同会话，
短暂取得原生所有权，在同一SQLite事务保存初始V1增量和本地初始化标记，完成后释放准备资源。
已占用引擎、既有正文或不同初始化身份会拒绝执行。同一操作重试恢复原CRDT身份；同时核对插入向量和删除集合，正文已变化（包括纯删除）时拒绝重新初始化。
初始事务没有删除，既有只保存initial_vector的本地标记也可直接校验，不改变SQLite结构或FRB接口。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

Future<CollabController> openNewDocument({
  required CollabDocumentConfig config, // 已取得正式docId，账号分区由包计算。
  required CsesCollabGateway gateway,
  required String operationId,
  required String paragraphId,
  required DateTime createdAt,
  required Future<void> Function(PreparedDocument) persistInitialSnapshot,
}) async {
  final prepared = await DocumentBootstrapper.prepareBlank(
    config: config, operationId: operationId,
    paragraphId: paragraphId, createdAt: createdAt,
  );
  // 宿主保存{docId: prepared.documentId, blocks: prepared.insertDiffs}并核验业务结果。
  await persistInitialSnapshot(prepared);
  final controller = CollabController.cses(config: config, gateway: gateway);
  try {
    await controller.initialize(); // 恢复刚才落盘的同一份增量。
    return controller; // 视图卸载后由调用方await controller.close()。
  } catch (_) {
    await controller.close();
    rethrow;
  }
}
```

`PreparedDocument.snapshotJson`可供宿主创建恢复记录保存，`insertDiffs`每次返回独立的桌面HTTP Insert投影。
包不调用建档、目录或快照HTTP接口，不读取Common账号。示例之外的完整恢复流程由宿主管理：建档结果不明
不自动重发，已知docId继续同一文档，快照结果不明先回读核对。Demo实现见根项目`lib/src/demo/document_creation/`。

初始化生成root与一个空paragraph；根子序列使用Y.Array，正文使用空Y.Text，不创建业务标题或封面，不进入用户撤销历史。
普通正式打开和清缓存不触发初始化。本机初始化过的文档检测到不同CRDT来源的远端根时，返回
`DOCUMENT_BOOTSTRAP_CONFLICT`并停止补传和自动重试，保留本地数据供恢复。HTTP快照与PaaS根来源仍需真实服务联调确认。
本地准备、HTTP成功、协同ready均不等同服务端正文持久化ACK。

真实FRB/SQLite及桌面数据层互通可在包目录运行（先按下文构建宿主动态库；Node使用18或更新版本）：

```bash
flutter test --no-pub \
  --dart-define=BOOTSTRAP_DESKTOP_ROOT=/path/to/cses-client \
  --dart-define=BOOTSTRAP_PACKAGE_ROOT=/path/to/blockcraft/package \
  --dart-define=BOOTSTRAP_NODE_EXECUTABLE=/path/to/node \
  test/document_bootstrapper_native_test.dart test/prepared_document_test.dart
```

未提供桌面路径时互通项显式标记跳过；普通原生准备/编辑/重开项仍需真实动态库，缺库直接失败。
该测试不连接真实业务服务，也不替代桌面窗口或手机在线验收。

## 编辑器与同步边界

`DocumentEditorController`独立拥有AppFlowy内存文档、输入继承、选区和本地历史，
`DocumentEditorView`只借用正文状态，复用原T/Aa/布局/添加与划词菜单。
独立会话默认空宿主服务，不初始化Rust、SQLite或网关；业务能力由实例上下文注入。

```dart
import 'package:flutter/material.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

final editor = DocumentEditorController();
final view = DocumentEditorView(editorState: editor.editorState);
// 将view移出组件树后，由创建方释放：
// await editor.close();
```

`CollabController`继续拥有协同资源，并向独立编辑会话挂载数据适配器。
本地事务依次执行身份准备、默认格式、模型校验、输入继承及同步发布；远端投影不回送。
投影隔离只覆盖AppFlowy同步改树阶段，不延长到Future收尾微任务；同步回放后的立即本地输入仍正常发布。
同步适配器解绑后，外部持有的编辑会话仍可编辑；外部会话由创建方释放。
既有`CollaborativeEditorPage(collab: ...)`调用方式不变；本地入口的返回值变化见下节。
历史裸EditorState/适配器保留原宿主服务解析兼容入口，新的独立会话显式隔离服务。

## 离线本地编辑与能力配置

`showCollabImageComposer`目前提供本地块编辑与模板预览，返回`Future<void>`；已移除PNG生成、图片结果类型和输出尺寸参数，不接入截图导出。
无需创建`CollabController`、登录、SQLite或网关，不初始化Rust文档；可与已有协同文档同时使用。

```dart
import 'package:flutter/material.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

Future<void> editLocal(BuildContext context) => showCollabImageComposer(
  context: context,
  initialText: '本地正文',
  editorConfig: EditorConfiguration(
    blocks: [EditorBlock.paragraph, EditorBlock.heading, EditorBlock.quote, EditorBlock.table, EditorBlock.formula],
    headingLevels: {1, 3},
    inlineFormats: {EditorInlineFormat.bold, EditorInlineFormat.textColor},
    alignments: {'left', 'center'},
    nextParagraphStyle: false,
    keyboardToolbarItems: [
      EditorKeyboardToolbarItem.table,
      EditorKeyboardToolbarItem.formula,
      EditorKeyboardToolbarItem.textStyle,
    ],
    maxCharacters: 10000,
    maxBlocks: 100,
  ),
);
```

`EditorConfiguration`在构造时复制并冻结集合，每个编辑器独立持有，创建后不支持热替换。
`blocks`是完整启用列表，按配置顺序显示块类型；标题级别允许1～9的非连续集合以保留桌面与历史正文能力；移动端添加和类型菜单统一最多显示H6，与启用集合取交集。
基础paragraph必须保留，保证空文档、回车和删除末块的落点；无效配置在创建资源前拒绝。
默认启用包内已注册的全部25种用户块类型，标题菜单提供H1～H6，已有H7～H9仍可读取：正文、标题、引用、三类列表、代码、高亮、表格、分割线、分页符、公式、Mermaid绘图、图片、链接、音视频、附件、网页/Figma/掘金嵌入，以及会议/任务/KR引用。
表格行/单元格和绘图源码按所属容器隐式启用，不单独出现在添加菜单。
这表示开放现有移动端实现，不代表41种桌面块已全部适配；仍按根仓库适配表的支持范围使用。
`EditorConfiguration.text`保留原六类文字块/H1～H4预设；也可通过`blocks`和`inlineFormats`选择更小的功能集合。

字符格式可分别启停加粗、斜体、下划线、删除线、行内代码、字号、颜色、字体/字距/倍率、上下标、链接、行内公式和提及。
字号菜单及命令使用`fontSizes`，默认12/16/20/24/28/32/36像素；对齐、下一段样式、行高写入及正文容量分别配置。
`keyboardToolbarItems`配置内建键盘入口及顺序。收起键盘不参与配置：有内建或宿主自定义入口时自动固定在最右侧，其余入口单行横向滚动。默认使用`EditorKeyboardToolbarItem.defaults`，保留原六个菜单入口及收起按钮；传空列表`[]`隐藏内建入口，没有宿主动作时隐藏整条，不留高度或分隔线。列表构造时冻结，重复项会抛出`ArgumentError`。
可选原入口：`addBlock`（加号）、`blockType`（T）、`textStyle`（Aa）、`blockLayout`、`image`、`mention`；`todoList`提供原生待办直达按钮，与T菜单共用类型转换，保留正文、格式和选区，已是Todo时不重置勾选状态。
“更多→常用”可直接放到键盘上：`link`、`video`、`attachment`、`audio`、`bookmark`、`embed`、`juejin`、`figma`、`table`、`callout`、`meeting`、`formula`、`mermaid`、`inlineFormula`、`divider`、`pageDivider`，图片与@用户也可直接配置。
`spreadsheet`、`multiTable`、`mindMap`保留原常用面板的占位行为，只提示“暂未支持”，不创建正文；能配置展示不代表这些块已适配。
键盘直达动作与更多面板复用同一目录和插入流程，包括模态隔离、稳定位置、取消/失效拒绝写入和焦点恢复。入口仍与块/格式能力取交集，例如未启用图片块，即使列表包含`image`也不会显示图片按钮。
旧加号布尔参数已移除；通过包含或省略`EditorKeyboardToolbarItem.addBlock`控制加号。隐藏入口仅改变键盘菜单，不禁止已启用的命令、快捷输入、划词操作或更多面板中的同类动作。
空格式集隐藏Aa入口；空对齐集隐藏对齐按钮。原工具栏、划词菜单、快捷键、Markdown转换及本地事务校验共同使用配置，直接命令和粘贴同样受约束。
粘贴保留纯文本，不解析HTML、Markdown或创建链接。默认容量100000个UTF-16单元（不计段落分隔换行）、500个正文节点（含容器结构子块），可由配置调整。
默认业务端口为空，不继承活动协同文档的账号、上传、会议/任务详情或头像服务。
如需从本地数据提供业务引用，可显式传入`services: CollabHostServices(...)`，服务由调用方持有；未提供服务时业务选择无法完成、详情仅保留引用快照；不伪造引用或业务数据。
媒体默认可通过链接添加；未注入上传服务时不显示本地上传入口，嵌套面板也不回退到全局上传服务。
资源链接的实际加载遵循平台和网络条件，不会因此启动文档协同。
本地不创建块锁管理器，不提供锁定/解锁菜单，锁属性写入被拒绝；原协同文档的锁服务和协议保持。

预览深复制正文并复用同一块组件；关闭输入、选区服务和正文点击，不显示光标、选区、工具栏、更多按钮、锁标或空白输入提示。
返回编辑保留原正文及历史；再次预览捕获新快照。内置五款本地渐变模板，或传入ID唯一的`List<CollabImageTemplate>`；模板切换不进入正文历史。
预览正文使用独立可滚动视图，尚未实现完整长图截图或导出。

路由完整退场后释放本地编辑与预览资源；内容只保留在本次会话内，不自动保存、不访问相册或服务端。
`LocalEditorController(configuration: ...)`及`DocumentEditorView`可通过公开入口用于自行装配；创建者在视图卸载后等待`close()`。
现有协同会话默认`EditorConfiguration.document`兼容预设，完整块及复杂业务端口保持，不受本地配置影响；该预设不能用于本地控制器。

## 宿主自定义编辑表面

宿主业务页面通过公开的`DocumentEditorController`持有编辑会话，可自行配置AppFlowy正文的块、行内对象和样式，再用`EditorInteractionShell`复用划词菜单与快捷栏。借用的正文及滚动控制器由宿主在视图卸载后释放。`handleDocumentParagraphEnter`和`applyDocumentBlockShortcut`提供通用输入/块转换，所有事务仍受宿主设置的保护策略约束。

`EditorCommandContext.copySelection`可选接管移动菜单的复制/剪切，接收调用时捕获的选区与`cut`意图。宿主负责内容序列化、等待剪贴板写入成功后删除，以及正文、选区、权限和关闭的异步失效检查；回调完成后菜单不再重复写入或删除。未配置时沿用原有行为。自定义键盘命令需显式复用同一端口；通用包不解释宿主业务对象。

今日导向页面、草稿模型、本地存储和业务块已迁到宿主`lib/src/daily_guidance/`；本包不再导出日记业务API。包仅提供通用编辑与共享数据协同，业务扩展不应反向加入包内。宿主实现与迁移验证见[实施记录](../../docs/verification/offline-journal-20261022/host-implementation.md)。

自定义正文可通过`EditorInteractionShell.keyboardActions`注入`EditorKeyboardAction`（稳定唯一id、名称、图标、enabled与异步onPressed），按顺序接在内建项后，保留标签与禁用态。工具栏在同一动作执行期间同步拦截其他快捷入口和旧子菜单回调，并关闭禁用子菜单，完成后恢复；宿主负责业务资源、账号/权限/目标失效保护，以及模态退场和输入恢复。原生工具栏不认识感悟或领航员等业务名称。默认空动作不改变其他消费者。

自定义栏目中的扁平列表需在`EditorConfiguration(listConversionContainerTypes: {'host-section'})`显式声明结构父节点类型，才能在有序、无序和Todo之间直接互转。集合复制后冻结，默认空；授权父节点必须没有Delta，所选列表必须为同一父节点下的无子项叶子。该配置不注册自定义块，不绕过宿主事务保护，也不扩大Enter、Backspace或缩进范围；根层与高亮块仍沿用原有支持。宿主负责自己的栏目渲染和边界校验。

自定义渲染器可组合`decorateEditorUserMention`并用`EditorUserMention.read/tryRead`校验或读取原生用户对象；普通文字不得携带对象身份属性。用户WidgetSpan内部不重复继承系统字号，由正文统一缩放姓名及头像。键入@可调用`handleEditorUserMentionTrigger`，显式入口可用`showEditorUserMention`，均借用本实例`EditorCommandContext.services`。宿主业务行可通过`pickEditorMentionUser(context, state)`复用同一人员选择及权限保护（不自动插入），并将`EditorUserMention.createDelta(user)`返回的原生人员对象和空格放入自有原子事务；调用方负责保存、复核目标及恢复键盘。独立正文控制器复用原生对象事务；`localOnly`会话使用可被宿主事务保护直接校验的局部文字增量，支持本地撤销重做，不创建同步连接。

## 图片点击

正式图片块的图片本体点击调用可选的 `CollabHostServices.onImageTap(url)`，完整传递当前原始链接，包括查询签名和片段。宿主负责预览路由及资源，异步回调应在预览关闭后完成；同一图片回调未结束时忽略重复点击。编辑和预览均可用，题注与更多菜单不触发。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

CollabHostServices imageServices(Future<void> Function(String url) openPreview) =>
    CollabHostServices(onImageTap: openPreview);
```

点击图片收起正文键盘，回调结束后不自动恢复正文选区或焦点；之后点击正文仍可继续输入。未配置回调或链接为空时不派发事件，但仍屏蔽图片点击的正文焦点。事件不改写协同正文或撤销记录。当前图片/宿主仍有效时，回调异常经 `onError` 报告并显示失败提示；卸载、换源或换会话后的迟到失败忽略。data/blob地址原样交给宿主，由宿主判断是否支持预览；包不提供默认图片预览页面。

## 原生构建与测试

### 共用表情目录

文档图标和高亮块复用`CollabEmojiPicker`与手机底部弹窗，包含桌面同源八类1812个默认表情、1350个肤色序列、中英文/拼音/首字母搜索和进程内最近12项。搜索和底部Tab固定，中间始终为一个完整分类列表：点击Tab平滑定位标题，手动滚动同步选中并自动展示对应Tab，“全部”定位顶部当前/最近区域。搜索时展示结果，点击分类退出搜索并定位。既有Unicode、组合表情及自定义前缀保留，不在打开时迁移。

目录缓存按列数、查询、肤色、当前项和最近项失效，固定行高随标题文字缩放调整，列表仅挂载可见行。滚动联动只比较八个分类偏移并更新Tab，不重建整个选择器；两屏以内直接滚动300毫秒，远距离淡出90毫秒后在透明状态定位到目标附近，再滑入300毫秒并淡入180毫秒，避免连续创建/回收整段目录。新点击或用户拖动可接管，关闭后旧动画结果失效，过渡期间不提交表情。每格借用父级Material绘制墨水反馈，保留选中边框、长按名称提示、键盘激活及无障碍语义；独立使用需提供Material祖先。

表情列表与Tab真机性能回归从Demo宿主根目录运行，使用性能构建及随系统出帧的`benchmarkLive`策略，分别记录首次分类浏览、连续双向甩动、重复Tab定位/动画接管、Tab横滑。测试使用实际公共底部路由与选择器、本地保存回调；不进入账号或在线文档，完成性能采集后才转换截图表面。输出为`build/emoji-device/performance.json`及真机PNG，可用`COLLAB_EMOJI_DEVICE_OUTPUT_DIR`指定目录：

```sh
flutter drive --profile --no-dds \
  --driver packages/cses_document_collab/test_driver/emoji_performance.dart \
  --target packages/cses_document_collab/integration_test/emoji_scroll_test.dart \
  -d ANDROID_DEVICE_ID --no-pub --keep-app-running
```

必须保留`--keep-app-running`；完成后重新构建普通Demo，并用`adb install -r`覆盖恢复，避免设备停留在测试入口或清除应用数据。帧耗时按实际刷新率评估，不用默认测试出帧节奏或调试构建推断流畅度。

独立排除测试绑定开销时，同一入口可使用`flutter run --profile --no-dds --no-pub --dart-define=EMOJI_MANUAL_PERF=true --target packages/cses_document_collab/integration_test/emoji_scroll_test.dart -d ANDROID_DEVICE_ID`。此模式使用普通`WidgetsFlutterBinding`和系统触摸，`ext.emoji.frames`只向本地VM服务提供最多20000帧的构建/栅格耗时（微秒），传`reset=true`清空；不初始化账号或读取文档，退出进程释放全部采样状态。测量后仍需覆盖恢复普通Demo。

数据与桌面实际使用的`@cses/ui 4.35.6`中`CsEmojiPickerComponent`同源：`@ctrl/ngx-emoji-mart 9.2.0`（Unicode 14目录），以及组件随包提供的CLDR release-48中文名称、拼音和搜索别名。生成文件不可手改，更新时在包目录运行：

```sh
node tool/sync_desktop_emoji_catalog.mjs /path/to/cses-client
```

同步工具校验分类/身份/肤色映射并记录源文件SHA-256，同时维护[许可与来源](third_party/emoji/README.md)；选择器将MIT和Unicode完整许可注册到Flutter许可页。目录无需网络或图片包，具体字形由系统字体提供。最近记录和肤色不跨进程持久化，不提供双人混合肤色编辑器。

### 构建与回归

Android 通过本包 android/Cargokit 构建 rust。插件及宿主需使用 compileSdk 36 或更高版本，最终宿主的最低运行版本仍为 API 24。安装对应 Rust Android targets 和 NDK 后，从最终 App 执行 Flutter build。原生库名仍是 cses_collab_core。

iOS 使用 `ios/cses_document_collab/Package.swift` 的本地动态 XCFramework。在 Flutter/Xcode 解析 SPM 之前执行：

```bash
/path/to/cses_document_collab/tool/build_rust_ios.sh debug
# Archive 前使用 release；生成物不进入 Git。
```

原生依赖由 Cargo.lock 固定，libc 显式固定 0.2.186 以兼容 backtrace 在 iOS 上使用的 dyld 声明。

所需 targets 为 aarch64-apple-ios、aarch64-apple-ios-sim、x86_64-apple-ios。构建工具以包位置为根，不依赖调用方 cwd。CocoaPods podspec 也随包保留，当前 demo 验证 SPM；CocoaPods 单独标为未验证。

本仓库 Demo 的 Runner 构建阶段会自动执行 `scripts/build_rust_ios_xcode.sh`，增量构建本包
并刷新 SwiftPM 已处理的 framework；IDE 完整启动 iOS 无需手动重建。其他 SPM 宿主需自行
配置对应构建集成。首次解析缺失的 XCFramework 前仍需先运行上述包内初始化脚本；
热重载/热重启不能替换已加载的原生库，Rust 修改后须停止并重新启动调试。

包内开发先由宿主配置 AppFlowy override。独立运行包测试时可在此目录建立不提交的 pubspec_overrides.yaml，使用同一 fork；本目录执行：

```bash
flutter pub get
flutter_rust_bridge_codegen generate # 使用 2.13.0
cargo build --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml
flutter test --no-pub
flutter analyze --no-pub
```

原生回归需要真实宿主动态库。`collab_controller_native_test.dart` 对缺库直接失败，避免将跳过测试当作验证。异地引用门禁会复制本包到临时目录，由另一个 Flutter 宿主只通过公开入口加载 native Doc、呈现只读编辑页并验证 SQLite 重开：

```bash
tool/verify_portable_package.sh ../appflowy_editor
```

包保留已有块支持范围、未知数据保护和模型只读规则。正式正文（含代码块）出现未适配行内对象时，仅将所在段落投影为不可编辑占位，完整保留原始Y.Text与属性；其他已适配块继续编辑，含占位的父容器不可连带删除。未知类型仍保持保护，用户、会议、任务、文档四类提及的普通正文支持另见下文，锁、修订和图片题注等既有只读保护仍生效。上传、私有资源鉴权、业务元数据、服务端保存及租户权限由宿主/服务端提供，真实环境联调须单独验收。

## 共用编辑视图与场景配置

离线正文、协同正文、图片制图和宿主业务页面统一使用`DocumentEditorView`；菜单、字符装饰、快捷键、剪贴板、选区及预览规则由同一实现维护，不按在线状态另建分支。`EditorConfiguration`声明块、格式、标题级别、工具栏入口和嵌套能力；`EditorViewConfiguration`注入宿主皮肤、结构渲染和业务动作。业务模型/事务保护、草稿存储和协同绑定分别由宿主会话持有，视图只借用正文。

标题菜单默认均逐级展示H1～H3→H4→H5→H6，重新打开按当前标题恢复，进入普通段落重置；非连续级别会跳到下一已启用项。确有需要时可显式设置`progressiveHeadingMenu: false`直接展开，不能再依赖编辑器种类隐式改变菜单。`structuralIndentation: false`关闭原生嵌套缩进；显式授权的文字/列表平面缩进仍走同一命令。

```dart
import 'package:flutter/material.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

final controller = LocalEditorController(configuration: EditorConfiguration(
  blocks: [EditorBlock.paragraph, EditorBlock.heading, EditorBlock.todoList],
  headingLevels: {1, 2, 3, 4, 5, 6},
  paragraphLayout: true,
  structuralIndentation: false,
));
final view = DocumentEditorView(
  editorState: controller.editorState,
  configuration: EditorViewConfiguration(
    style: (context, style) => style.copyWith(cursorColor: Colors.brown),
  ),
);
// 视图移除后 await controller.close()。
```

宿主可通过`blockBuilders`接收视图新建的私有渲染器并增加自己的结构块，不能复用跨文档可变builder；额外结构数据仍需宿主的事务和恢复校验。`characterShortcuts`只处理业务特例，未处理的输入交给通用链；`keyboardActions`追加业务菜单，不复制内建操作。仅更换展示配置会保留正文、滚动和撤销历史；借用控制器由创建者释放。实现和验证见[统一核心记录](../../docs/verification/offline-journal-20261023/shared-editor.md)。

## 人员提及端口

人员头像和选择器由宿主创建，协同包不提供默认头像组件、图片URL规则或人员搜索界面。通过公开入口配置：

- `mentionAvatarBuilder(context, {userId, name, size, avatarUrl})`：返回宿主头像Widget。`size`为逻辑像素边长；正文的`avatarUrl`为null，人员选择器自行使用宿主人员资料URL。协同包只约束尺寸并排除重复无障碍描述。未配置时只显示姓名，无头像间距或图片请求。
- `pickMentionUser(context, {keyword, canEdit})`：宿主打开单选界面，等待界面完全退场后返回`CollabMentionUser`；取消返回null，异常由编辑器报告。`canEdit`是本次调用期间借用的只读权限信号，不得释放或保留；false后禁止确认。宿主负责搜索、鉴权、界面/监听/定时器的创建与释放。未配置时输入@作为普通文字，工具栏提示宿主未提供选择器。
- 用户提及点击仅调用`onMentionTap`，传递类型、ID、原始姓名与完整只读属性；不提供人员资料/复制/删除面板。未注入点击回调时不响应，不暂停正文输入。人员目录由宿主选择器/详情页持有，`CollabHostServices.mentionDirectory`已移除；宿主仍可复用公开的`CollabMentionDirectory`数据契约。

```dart
import 'package:flutter/material.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

// 用宿主自己的头像和人员路由替换示例内容。
final services = CollabHostServices(
  mentionAvatarBuilder: (context, {required userId, required name,
    required size, avatarUrl}) => CircleAvatar(
      radius: size / 2, child: const Icon(Icons.person)),
  pickMentionUser: (context, {required keyword, required canEdit}) async {
    final route = MaterialPageRoute<CollabMentionUser>(builder: (context) =>
      Scaffold(body: Center(child: TextButton(
        onPressed: () => Navigator.pop(context, canEdit.value
          ? const CollabMentionUser(id: 'u1', name: '张三') : null),
        child: const Text('张三'),
      ))));
    final selected = await Navigator.of(context).push(route);
    await route.completed;
    return selected;
  },
);
```

输入@、键盘工具栏及更多面板统一调用宿主选人端口。协同包保存稳定块位置，暂停正文输入，等待结果后校验权限、会话、页面与原内容，拒绝重复调用和迟到/失效结果；权限一旦撤销，本次结果即作废，重新授权需重新选人。取消或失败保留正文；有效完成后恢复光标/键盘。宿主必须校验账号/企业，不能复用旧会话缓存。正文只同步人员显示名/ID及原有提及属性，头像URL、搜索和部门/职位属于本地资料。

Demo在`lib/src/demo/mention_avatar.dart`实现公共头像地址、圆形裁切和失败首字，在`mention_picker.dart`实现搜索/去抖/列表/重试，`document_host.dart`注入两个回调。其他宿主可完全替换这些UI而无需依赖Demo。迁移时请显式配置`pickMentionUser`与`mentionAvatarBuilder`，旧`mentionDirectory`构造参数须移除，目录改由宿主的选人回调捕获；点击详情使用`onMentionTap`。

代码块/图片题注、未知实体与localDraft保持原保护范围；同步任务参与人业务副作用尚未提供端口。历史Android头像与桌面联调见根仓库`docs/verification/user-mention-20261014/user-mention-20261014.json`；本次UI迁移尚未重做真机/桌面联调。

## 会议、任务和文档提及（普通正文）

正式 `{mention: name}` 配合 `mentionType=meeting/task/doc` 和稳定 `mentionId`（兼容历史 `d:` 前缀），在段落、标题、列表、引用及高亮正文中显示类型图标+名称，不附加@，不再降级为只读占位。每个对象仍占一个UTF-16位置；普通文字、用户头像和公式可混排。点击先打开操作面板，明确选择“打开会议/任务/文档详情”才调用`onMentionTap`；未注入时详情禁用。仅会议/任务另提供“切换为卡片视图”，文档库提及没有卡片形式；三类均可删除提及，预览禁止转换与删除；独立撤销/重做恢复原始实体属性。姓名最长20000 UTF-16单元，ID最长512 UTF-8字节，非用户实体属性JSON最大65536字节。

原始编号、状态、文档类型、任务扩展等属性完整保留，嵌套对象的JSON排序稳定；属性快照仅供删除后恢复，普通编辑不回放陈旧业务状态。远端类型、身份、属性或同段正文变化使过期操作失效。新增搜索仍是人员入口，尚无会议/任务/文档提及搜索选择器或业务实体修改；业务详情导航由宿主实现；这三类提及保持部分支持，会议/任务引用卡片另为部分支持。代码块和图片题注、未知实体与localDraft继续遵循保护边界。验证与真机联调记录见仓库 `docs/block-adaptation.md`。


## 宿主统一提及点击回调

通过公开入口的 `CollabHostServices.onMentionTap` 接管用户、会议、任务、文档点击。参数 `CollabMentionTap` 包含 `type`（`CollabMentionType.user/meeting/task/doc`）、`id`、`name` 和 `attributes`。名称是共享正文原名，空名称仍为空；属性来自Y.Text，保留历史d:键、格式及未知扩展，不从人员/实体详情接口拼装，不包含移动编辑器的cses私有属性。所有嵌套Map/List均深复制且只读，宿主可独立保留事件。`mention.toJson()`返回`type/id/name/attributes`，其中`type`为`user/meeting/task/doc`字符串，可直接`jsonEncode(mention)`；每次返回独立顶层Map，内部属性沿用只读快照。

用户提及仅在配置回调时响应点击，编辑包不提供用户资料面板；未配置时不处理点击，也不暂停输入或恢复光标。会议/任务/文档始终先打开操作面板，“打开详情”才调用宿主；未配置回调时该操作禁用。预览也可通过打开详情导航，切换卡片和删除禁用。任务卡片的详情按钮复用该回调，attributes为已投影的taskId/title引用props。支持同步或异步处理；导航应返回直到详情退场完成的Future。回调期间暂停正文输入并忽略同编辑器的重复点击，完成后仅向仍有效的原页面恢复焦点。同步/异步异常向原宿主onError报告并在有效页面提示，不补开默认面板；已关闭或被新会话替代的编辑器不恢复键盘。宿主仍负责业务鉴权、跨账号异步失效、路由和外部资源生命周期。

下面的函数返回可注入控制器的services，navigatorKey由宿主持有并传给MaterialApp；将示例builder替换为四类业务详情即可：

```dart
import 'package:flutter/material.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

CollabHostServices mentionServices(GlobalKey<NavigatorState> navigatorKey) =>
    CollabHostServices(onMentionTap: (mention) async {
      final navigator = navigatorKey.currentState;
      if (navigator == null) return;
      final route = MaterialPageRoute<void>(builder: (_) => Scaffold(
        appBar: AppBar(title: Text(mention.name)),
        body: SelectableText('${mention.type.name}: ${mention.id}'),
      ));
      await navigator.push(route);
      await route.completed;
    });
```

四类原始属性JSON均限制为65536字节；正式投影完整传递，未就绪或损坏的属性拒绝派发并报告失败，不制造原始属性。新插入用户的身份快照立即可用；原有手工用户投影可不带快照展示，但配置回调后须等待真实属性就绪才能派发；未配置回调不报属性缺失。编辑包不内置用户业务路由或资料面板。用户引用仍可用正文选区删除并撤销/重做。

用户点击面板移除、缺省不响应及统一回调兼容验证见根仓库`docs/verification/mention-integration-20261015/mention-user-tap-only-20261015.json`。


## 会议引用卡片

正式 `meeting` 是无正文、无子块的引用卡片，保留 `props.meetingId/title/number`。
移动端先使用共享标题和编号，空标题显示“未命名会议”。可通过宿主`loadMeetingCard`加载本地会议详情，展示状态、开始时间（设备本地时区）、主持人和参与人数；业务标题/编号可覆盖本地展示，但不写回共享props。
“更多→会议”调用宿主注入的 `pickMeetingReference` 选择/创建会议引用；未注入时隐藏新增入口。包不提供会议输入表单或业务创建逻辑；卡片右上更多菜单提供“删除卡片”和“在下方插入”；删除仅移除本文档引用，业务会议不受影响。卡片不再显示“编辑引用”入口。
插入按稳定正文位置定位，支持根/高亮容器、空段替换与非空段后插入、撤销/重做。
引用修改工具保留逐字段补丁和版本校验；卡片删除按稳定块ID和展示时属性校验，远端变化或撤权拒绝过期删除。删除父容器最后一项时补空段落，支持独立撤销/重做；预览/只读隐藏编辑操作入口。
ID不可为空且最多512 UTF-8字节，标题最多2000、编号最多256 UTF-16单元；超限、缺身份或非void结构仍作为受保护占位保留。
非删除操作保留原始未知属性；删除后的撤销仅恢复已投影的引用字段，不保证恢复未知扩展或meta。

宿主通过`CollabHostServices.onMeetingCardTap`处理“加入会议／查看会议”按钮；只有该按钮派发回调，标题、状态、卡片背景和留白均不派发。预览也允许主按钮操作，删除仅移除引用，不触发详情事件。

状态配色与桌面一致：`NotStarted`未开始为蓝色、`InProgress`进行中为绿色、`Pause`已暂停为橙色，`Completed`已结束和`Canceled`已取消为灰色。已结束/已取消显示“查看会议”，其他状态显示“加入会议”；真实入会/查看逻辑由宿主回调负责。删除引用为底部左侧中性色次要按钮，主操作在右侧；窄屏/大字空间不足时分行，避免两个操作重叠。
这是独立会议卡片的端口，与正文`onMentionTap`分开；参数是会议ID及当前展示的业务标题/编号（详情未提供时沿用共享引用）。
未配置回调时禁用主按钮，编辑模式仍可删除引用。宿主持有路由、认证与业务资源，并返回直到详情退场完成的Future；点击关闭正文键盘并暂停输入，完成或失败后均不恢复原正文焦点、不自动弹键盘，只有用户重新选择正文才进入输入。回调期间禁用同一卡片导航和删除；失败上报原宿主，失效会话不提示。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

CollabHostServices meetingServices(
  CollabMeetingCardLoader loadMeetingCard,
  Future<void> Function(String meetingId) openMeeting,
) => CollabHostServices(
  loadMeetingCard: loadMeetingCard,
  onMeetingCardTap: (meetingId, title, number) async {
    await openMeeting(meetingId);
  },
);
// 将返回的services注入宿主持有的CollabController，关闭时await controller.close()。
```

`loadMeetingCard(meetingId)`返回`Future<CollabMeetingCardData?>`，`state`使用公开`CollabMeetingCardState`；可用`fromValue`映射服务端原始状态。宿主拥有认证/HTTP，包不释放它们。仅在卡片挂载、会议ID或宿主变化、手动失败重试时读取详情；加入/查看按钮只调用宿主回调，执行前后均不额外请求详情，同一卡片重建复用请求，换ID/会话或销毁后忽略迟到结果，不把业务状态写入协同文档。

未配置加载器时保留共享引用并显示“状态未知”；明确返回null表示会议不存在，`Delete`表示已删除，二者均禁用主按钮。未知状态不伪造未开始；加载中或失败也禁用主按钮，失败显示重试并向原宿主报告。Demo通过`lib/src/service/cses_meeting_card_service.dart`及Common的`POST /meeting/getDetail`加载详情，前后校验账号、企业和会话。

新增引用的宿主端口如下，宿主页面自行处理会议搜索/创建及认证，返回引用值并等待退场；取消返回null。`canEdit`仅在本次调用期间借用，false后不得确认，不保留或释放它。包拒绝撤权、关闭、会话替换与插入位置失效的迟到结果。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

final services = CollabHostServices(
  pickMeetingReference: (context, {required canEdit}) async {
    // 在这里等待宿主会议选择或创建页面，成功后返回真实业务身份。
    // 本示例取消；业务创建请求必须在宿主完成，包只插入引用。
    return null;
  },
);
```

Demo实现在根项目`lib/src/demo/meeting_reference_picker.dart`，只填写已有引用，不创建业务会议；通过公开包入口使用`CollabMeetingReference`，不传EditorState或包内类型。

当前为部分支持：没有会议搜索选择器或详情实时推送订阅；状态按上述时机重新读取。主按钮仅派发宿主回调，Demo当前回调只记录事件，不实际入会或打开业务详情；纪要/回放或收集KR也未内置。
引用编辑不创建或修改业务会议，会议KR列表仍未适配；Android/iOS真机与实际桌面双端待验收。
Rust内部映射复用现有属性桥接载体，没有FRB签名/ABI变化，不需要重新生成桥接文件。

历史整卡点击、直接删除与键盘抑制验证见`docs/verification/meeting-card-20261015/meeting-card-actions-20261015.json`；状态配色与主按钮验证见根仓库`docs/verification/meeting-card-20261015/meeting-card-status-20261015.json`。当前删除入口统一到右上更多菜单，最新菜单回归见适配表。

主按钮仅回调宿主、执行前后不新增详情请求的后续验证见`docs/verification/meeting-card-20261015/meeting-card-callback-only-20261015.json`。


## 提及操作与卡片视图

用户提及保持头像+姓名并直接通知宿主。其他三类点击先显示底部操作面板：打开详情、删除提及；只有会议和任务额外提供“切换为卡片视图”。关闭面板不派发事件；只有打开详情调用`onMentionTap`，携带该原子的原始属性。切换、删除均只处理文档引用，不调用详情接口或宿主点击回调。面板期间暂停正文输入，等待退场动画后执行；操作前复核稳定身份、原子属性、正文及宿主会话，预览禁用转换/删除。

会议/任务转换使用桌面正式`meeting`/`task` void块。原段落保留前文，卡片插在它后面，后文拆成新段落，富文本、相邻提及和公式继续保留。支持根与高亮容器内普通正文；空前文仍保留原块，与桌面一致。转换是一项独立撤销记录，撤销/重做跟随稳定源块位置；远端修改前文、卡片或拆出后文后旧转换历史整体拒绝，避免覆盖协同内容。会议引用标题沿用2000 UTF-16上限，超限转换被拒绝，原提及仍保留；任务标题上限20000。转换不复制提及业务状态到卡片，保留身份与标题；撤销恢复原提及完整属性。

任务卡片按下方详情端口展示业务快照或共享标题，右上展开图标调用`onMentionTap(type=task,id=taskId,name=title,attributes={taskId,title})`，删除位于右上更多菜单，仅移除引用，支持撤销/重做和后置段落行首退格。未知原生任务props保留；删除卡片后撤销仅恢复已投影字段，不能保证未知props/meta。损坏引用/非void结构继续受保护。会议卡片沿用状态加载与`onMeetingCardTap`主按钮，转换本身不调用任何点击回调；详情加载仍仅由卡片展示生命周期触发。

文档库提及始终保留图标+名称的行内形式，不提供卡片/链接视图切换，也不创建局部卡片状态。打开详情仍调用宿主，删除与撤销保留原始dc_t/ac_t及未知属性；仅打开面板或详情不修改共享内容或新增历史。会议和任务是唯一支持提及转卡片的实体类型。

本轮验证与限制见根仓库`docs/verification/entity-mention-20261015/entity-mention-card-actions-20261015.json`；尚未进行真机安装与真实桌面同步验收。


## 任务卡片详情与布局

正式task引用的共享字段仍只有taskId/title。通过可选的`CollabHostServices.loadTaskCard`提供`CollabTaskCardData`本地展示快照，包不直接请求业务接口，不将详情写入Y.Text或共享props。

卡片按桌面样式使用白底细边：左上任务图标和优先级，右上负责人头像及展开/更多图标，中间标题和只读状态、起止时间，下方以分割线展示进度，再显示空间/项目/工作项路径和附件/子任务数。色板与桌面一致；标题预留两行，路径单行省略，起止时间各预留一行；窄屏长日期单行省略，行高随文字缩放增长。计数大于999时显示999+，语义保留原值。

`leaders`复用`CollabMentionUser`与宿主`mentionAvatarBuilder`，最多展示3位及其余人数；包不创建默认头像或请求图片，无头像构建器时隐藏头像组。时间按设备本地时区显示MM-dd HH:mm；progress为0～100百分数，已知0%仍在轨道起点显示圆点，null只显示灰色轨道。未提供标签、时间、路径或计数时隐藏对应信息并保留行槽留白，不伪造“一般/待开始/0”。加载使用同一行槽的静态骨架，失败/不存在反馈也复用统计槽，不推动后续正文。

只有右上展开图标调用`onMentionTap`，传type=task、共享taskId/title及原始投影引用props；卡片背景、标题、标签、路径和统计不触发导航，状态仅展示。业务详情标题只覆盖本地外观，回调name仍为共享标题。打开详情成功/失败均不额外调用加载器，完成后不恢复正文键盘。编辑时更多菜单提供“删除卡片”，只删除文档引用；预览隐藏更多菜单但保留详情入口。菜单捕获打开时的引用属性与宿主，远端改换引用、撤权或换会话后旧菜单不能删除新引用。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

final services = CollabHostServices(
  loadTaskCard: (taskId) async => CollabTaskCardData(
    taskId: taskId, title: '测试状态111–111',
    priority: const CollabTaskCardTag(name: '一般', color: '#59B463'),
    status: const CollabTaskCardTag(name: '待开始', color: '#E6E6E6'),
    progress: 0, fileCount: 0, subTaskCount: 0,
  ),
  onMentionTap: (mention) async {
    // 使用mention.id和type打开宿主页面，并等待页面完全退场。
  },
);
// 将services注入宿主持有的CollabController；关闭时await controller.close()。
```

加载器只在卡片挂载、任务ID/宿主变化或失败手动重试时执行；普通重建和详情回调复用当前快照。返回null表示任务不存在，data.deleted=true表示删除，异常显示重试并报告原宿主；加载中、失败、缺失/删除禁用详情，仍允许移除引用。换ID/宿主、关闭组件后迟到响应或错误被忽略，包不取消或关闭宿主持有的网络资源。

Demo的`CsesTaskCardService`复用Common POST `/taskManage/task/detail`，参数`{queryType:'detail',tableName:'task_v3',id}`，解析item中的priority/status/leaders[].user、startTime/endTime毫秒、progress、space/project/workItem及fileCount/subCount。请求前后检查账号、企业及会话；进度沿用桌面归一规则，限制0～100并保留两位小数。无详情端口只显示共享引用，不做隐藏的默认网络请求。尚无实时详情推送、任务状态流转编辑或内置业务路由，仍为部分支持。

验证与预览见根仓库`docs/verification/task-card-20261015/task-card-layout-20261015.json`。HONOR X70/Android16已安装并完成PRE真实任务卡片展示、编辑/预览详情回调、键盘抑制和删除/撤销/重做；最终任务引用及其他正文恢复，但删除撤销会重建审计meta并补默认depth=0。详情由Demo Toast确认，实际业务路由、本轮真实桌面同步联调和iOS未验收，见`docs/verification/task-card-20261015/task-card-phone-20261015.json`。


## Markdown 文件导入

宿主向 `CollaborativeEditorPage(collab: controller, pickMarkdown: pickMarkdown)` 注入 `Future<String?> Function()` 文件选择器。返回已校验的 UTF-8 文本，取消返回 null，失败抛异常；不注入时隐藏导入入口。Demo 使用系统单文件选择器，只接受 `.md` / `.markdown`，上限 5 MiB，文件读取和解析在后台执行。

编辑页右上角“导入 Markdown”说明范围后选择文件，内容以独立事务追加到文末，可整体撤销/重做，并沿现有协同及 SQLite 持久化链路发布。选择/解析期间禁止重复导入和正文输入；权限收回、控制器替换或退出页面后丢弃迟到结果。

支持段落、H1～H6、加粗/斜体/删除线/行内代码/链接、两种列表、待办、0～6级列表缩进、引用、围栏代码及语言、分割线、独立 HTTP(S) 图片。每个有序列表保留起始编号。表格按行转为带 ` | ` 分隔的富文本；行内图片及非 HTTP(S) 图片保留 Markdown 地址文字，不读取或上传本地资源。HTML 按文本保留，公式语法按普通文本保留；不增加表格、HTML或公式导入能力。超过六级的列表缩进按六级显示。

Android 真机验收（2026-10-15）：HONOR X70/Android16 从系统下载目录选择 `.md` 后成功追加15块；整批撤销/重做、说明页取消与系统选择器取消通过。实际手机 SQLite/WAL 回读核对原34块的ID、顺序和所检查投影保持，最终清理测试块且在线。见根仓库[验收记录](../../docs/verification/markdown-import-phone-20261015/markdown-import-phone-20261015.json)；iOS、服务器持久化ACK和实际桌面双端观察尚未验收。

## 文末点赞与全文评论

在 `CollabHostServices` 设置 `showDocumentFeedback: true` 显示整个文末区域，默认false。编辑、预览和只读正文均可显示，业务权限由宿主判断。启用后，头部及正文的最小高度为当前编辑视口的一屏（不包含点赞和评论），短文档首屏不显示互动区，上滑后才出现。长文档保持按需渲染；滚到文末时评论按钮下方仅留20个逻辑像素，系统安全区由页面另行保留。区域随正文滚动，不属于协同块，不参与撤销或同步。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

final controller = CollabController.localDraft(
  databasePath: '/host/updates.sqlite',
  services: CollabHostServices(
    showDocumentFeedback: true,
    loadDocumentFeedback: (documentId) async => CollabDocumentFeedback(
      likes: CollabDocumentLikes(isLiked: true, members: [
        const CollabDocumentLikeMember(userId: 'u1', name: '张三'),
      ]),
      commentCount: 3,
    ), // 替换为宿主读取接口。
    onDocumentLike: (documentId, likes) async {
      // likes.members为只读成员列表，likes.isLiked为点击前当前用户状态。
      // 调用点赞/取消接口，返回服务端确认后的CollabDocumentLikes。
      return null; // 取消或无变更时保留原状态。
    },
    onDocumentComment: (documentId, commentCount) async {
      // 打开宿主全文评论页面并等待关闭，返回最新评论数量。
      return commentCount;
    },
  ),
);
final page = CollaborativeEditorPage(collab: controller);
// 路由退出后由宿主 await controller.close()。
```

`loadDocumentFeedback(documentId)`提供初始成员、用户点赞状态和评论数量；不配置时初始为未点赞、空成员、0条评论。加载失败显示重试并禁用业务按钮，避免用未知状态发起点赞。宿主可通过`controller.feedback.refresh()`刷新数据；进行中的读写串行，不允许旧读取覆盖新写入。

`onDocumentLike(documentId, likes)`返回`CollabDocumentLikes?`，其中包含完整成员列表与当前用户状态。已点赞显示黄色实心按钮、“你已赞”和成员头像，再次点击由宿主处理取消点赞。成员头像复用`mentionAvatarBuilder`并传入成员`avatarUrl`；未提供构建器时显示姓名首字，不发起默认图片请求。成员列表由宿主保证身份唯一和排序，编辑器复制为不可修改快照。文末最多展示前10位成员头像，超出显示剩余人数；回调始终传递完整列表。

`onDocumentComment(documentId, commentCount)`返回`int?`，正数显示“评论全文（数量）”，0显示“评论全文…”。两个回调可同步或异步返回，null表示取消/不更新；失败和负评论数保留原值并报告重试提示。未配置回调时对应按钮禁用。点击先关闭正文键盘，等待期间禁用整个区域；状态和防重复操作由文档控制器持有，切换编辑/预览或滚动重建不会重置。关闭时忽略迟到结果并等待已发出的宿主操作，不自动恢复正文键盘。

点赞、评论、认证、成员资料和持久化均由宿主负责；包不创建评论输入框。开关在控制器创建时注入，变更配置需重建控制器。Demo提供内存点赞/取消演示及评论数量回传，尚未接入业务持久化接口。旧的单参数void回调须迁移至上述双参数、返回结果的签名。

## 移动端划词菜单

`CollaborativeEditorPage` 为 Android/iOS 挂载 `CollabMobileSelectionMenu`，与正文共用页面持有的滚动控制器；浮栏在长按或拖选结束后显示，滚动及选区变化由 AppFlowy 浮栏管理，不依赖键盘工具栏。编辑时提供复制、剪切、纯文本粘贴、全选、格式、链接及转行内公式；只读仅复制与全选。剪切等待剪贴板写入成功才删除，粘贴用单个事务保留前后正文及格式。

格式入口复用 `editor_shortcut_toolbar.dart` 的 T、Aa、布局控件，允许连续格式调整。文字链接仅修改 `href`（正式协同映射为 `a:link`），可预填共同链接、修改和移除，保留其余格式；支持完整 http(s)、mailto、tel 地址。公式入口预填选中文字并预览，确认后复用 `insertCollabInlineFormula` 原子替换和独立历史；取消不改正文，撤销恢复原文及格式。

`CollabTextRange` 保存块身份、父身份、正文与格式快照，整组重排可重定位；文字/格式变化、目标删除、权限撤销或页面退出后拒绝迟到写入。格式面板允许自身的格式变化，正文变化后禁用操作。同级跨段文字可格式化，链接/公式仅同段普通文字；跨容器/跨单元格、代码、题注和未知占位不开放本菜单。任务、会议、划词评论、背景图形及富文本剪贴板不在第一阶段。

回归覆盖见 `test/mobile_selection_menu_test.dart`。真实 Android 手势用本包 `integration_test/mobile_selection_menu_test.dart`，由 Demo 的 `flutter drive` 配合本包 `test_driver/integration_test.dart` 驱动并使用 `--keep-app-running` 保留既有应用数据；测试不登录、不访问在线文档。

## 普通及合并表格

正式 `table → table-row → table-cell → 正文块` 保留独立身份和共享类型。更多→表格直接在稳定正文位置后插入2×2表格，不弹出行列选择；窄表默认与正文左边缘对齐，编辑和预览一致，超宽时仍可横向滚动；顶部列操作条及左侧行操作条默认隐藏，点击表格后显示，点击外部收起；操作条选中整列/整行，蓝色高亮并打开浮动插入/删除菜单；插入再选择上下/左右方向。拖动列条右缘预览宽度，松手一次保存。每格右上角更多面板仅保留合并范围、合并和拆分；增删行列及列宽不在此处重复提供。跨越新增/删除位置的合并范围同步扩缩，删除主格所在行/列时将主格移动到存活覆盖区域。合并按行序移动非空正文到左上格，其他逻辑格仍以 `display=none` 保留；拆分后正文留在左上格，空格补空段落，与桌面契约一致。

网格支持横向滚动与跨行/跨列自然高度布局，长正文自动增高。列宽可设置48～480逻辑像素，拖动预览不产生协同更新，松手为单个可撤销事务；旧尺寸只在显示时回落，不自动回写。最多100行、50列且总格数不超过500，最后一行/列不能删除；不开放表格内嵌套新建。操作为独立可撤销事务；删除子树保留原共享节点并以内部meta标记归档，恢复时保留未知props/meta及删除期间到达的最新正文。普通快照不回放未触碰的布局属性。

面板期间暂停正文输入，完全退场后再按稳定ID、内容指纹和权限提交。远端变更或权限曾撤销即使旧面板失效，重新打开后继续操作；关闭时成对解绑借用监听。远端结构或单元格正文变化清除本地路径历史与选区，布局更新保留组件和光标；同步投影完成不会覆盖宿主刚撤销的权限。含未知占位的表格结构操作整体拒绝，列宽可独立设置；不完整/交叠/悬空隐藏或超限网格整体只读占位，原数据保留且不影响其他已适配正文。

尚无拖拽式多格选区、行列剪切复制粘贴或Markdown表格导入；Markdown仍按文本行保留。Android真机已验证新建、行列操作、合并拆分、拖动列宽及历史；iOS真机、真实桌面双向、两端同时修改行列结构的冲突场景及服务器持久化ACK尚待验收。完整验证记录见根仓库适配表及 `docs/verification/table-20261016/table-editing-20261016.json`。

## 网页资源的三种视图

卡片与嵌入头部只显示一个更多按钮，浏览器打开、复制链接、修改、删除、在下方插入和视图切换集中在同一操作面板。只读时保留打开/复制，隐藏编辑操作；修改和删除执行前重新校验当前块、权限及宿主会话。

网页、掘金和Figma资源可在嵌入、卡片、链接之间互转：分别使用桌面 `embed`（兼容旧品牌flavour）、`bookmark` 和 `paragraph` 的 `a:link`。嵌入使用WebView，卡片使用metalink；整段单一HTTP(S)链接点击可打开操作面板切回，混排正文不整块转换。每次转换独立撤销/重做，并检查稳定身份、过期URL和权限；未知原生props/meta通过既有替换身份链保留。

FRB片段新增可空href字段，已按2.13.0重新生成；升级时须完整重建原生库和宿主，不能只热重载Dart。Android构建与目标回归见适配表；真实网站、桌面双端及iOS真机仍需验收。


## 手机端卡片触摸回归

无正文节点不应由整卡矩形生成文字光标手柄。AppFlowy手机选择服务按是否有正文Delta统一处理：普通卡片单击不生成折叠光标手柄；正文光标或范围手柄拖动经过卡片时，沿用手势识别器并将非正文端点收窄为块边缘锚点，避免中断跨块拖选或遮挡卡片按钮。正文端点的光标矩形及拖动逻辑保持原样。

设备用例位于 `integration_test/mobile_card_pointer_test.dart`，从Demo宿主根目录运行：

```bash
flutter drive \
  --driver packages/cses_document_collab/test_driver/integration_test.dart \
  --target packages/cses_document_collab/integration_test/mobile_card_pointer_test.dart \
  -d ANDROID_DEVICE_ID --no-pub --keep-app-running
```

用例强制检查Android平台和真实MobileSelectionServiceWidget。覆盖会议、任务、网页、网页嵌入、掘金、Figma、附件、音频、图片、视频的真实点击及控件命中；正文光标拖动、长按选词、左右范围手柄及跨卡片拖动另有回归。业务回调、WebView/播放器使用本地替身，图片使用data URI，不登录、不读取在线文档或发出资源请求；键盘服务关闭以固定触摸坐标，测试目标是选择/手柄/按钮命中，不替代真实业务、播放器或输入法验收。直接以macOS的mobile样式运行不能替代此设备测试。

命令必须保留`--keep-app-running`，避免flutter drive默认在结束后卸载同包名应用并清理本地数据。完成后重新构建普通Demo APK并以`adb install -r`覆盖恢复，避免设备停留在测试入口。2026-10-16首次回归遗漏该参数，已发生本地应用数据清理，需要重新登录；测试未访问在线文档，修复不涉及正文数据格式。

## 媒体卡片的更多菜单

SVG图片使用flutter_svg绘制：带`.svg`后缀的远端图片复用CachedNetworkImageProvider的共享文件缓存，URL查询参数保留；无后缀SVG在位图解码失败后只读取已缓存文件并后台识别，不重复下载。data:image/svg+xml使用后台解码的字节渲染。加载/解析失败沿用图片占位，换源忽略旧结果；不改变尺寸、旋转、题注与编辑操作。复杂SVG能力以flutter_svg支持范围为准。

正式图片块的HTTP(S)图片使用 `cached_network_image: ^3.4.1` 展示，保留加载/失败占位及contain适配，按URL区分视图以处理同节点换源。默认缓存由组件库管理，图片块不释放全局缓存管理器；位图data URI仍在后台解码后用Image.memory展示，其他端blob上传保持占位。正文图片、文档头图及图片型icon共用`CollabCachedImage`：位图走CachedNetworkImage，SVG从同一缓存管理器读取后矢量渲染，无后缀SVG仅读取已有缓存进行失败回退；不创建或释放第二个全局缓存管理器。封面保留cover裁切与y位置；“调整封面位置”在固定预览区域内直接上下拖动图片，移除滑条，实时预览，保存才写入位置，取消保留原位置；图片型icon保留48px尺寸、原色及失败占位，Emoji保持文字渲染。头像、图库缩略图和网页缩略图不在本轮范围。

图片“编辑图片”弹窗仅设置链接、尺寸和对齐，只提供取消和保存；题注与删除均从卡片的更多菜单进入。无题注显示“添加题注”，已有题注显示“编辑题注”，打开只含题注输入的独立表单；取消或空保存不创建空题注，图片布局设置不会修改已有题注。

音频初始化时保留最终的播放按钮、时间行和轨道槽，在同一轨道位置显示不确定加载动画；未就绪显示--:--并禁用播放/拖动，完成后恢复可拖动进度条，缓冲也在同一位置加载，卡片高度保持。音视频的播放/暂停按钮直接显示在播放器上，音视频共用`CollabMediaTimeline`进度条，统一细轨道、圆滑块及当前/总时长；音频使用浅色卡片配色，视频进度条叠放在画面内底部。拖动预览目标时间，松手跳转一次。未知时长不允许跳转，进度只在局部更新，换源/退出等待已有跳转完成再释放控制器。音频、视频、图片和附件的管理操作统一收进一个“更多操作”按钮，各块已有的外部打开/下载、编辑、删除和下方插入从菜单进入。预览模式下仍可直接播放/暂停，音视频和附件的菜单仅保留打开，不显示编辑、删除和插入；图片预览隐藏更多按钮。菜单退场后才执行操作，期间权限变化或资源属性更新会使旧操作失效，重排后按稳定块ID定位。

本次按钮归并的验证范围见根仓库 `docs/verification/media-more-menu-20261016/media-more-menu-20261016.json`。


### 默认文字颜色真机回归

`integration_test/document_text_color_test.dart`复用共用正文颜色回归，在Android实际视口核对编辑/预览、左对齐/分散对齐的最终字符颜色。覆盖默认黑色、局部红/蓝/白色、链接色和高亮块颜色继承，并确认正文JSON不变且没有同步回送。显式白字使用深色字符背景方便截图辨认；测试正文仅存在内存中，不登录或访问已有文档。

从Demo宿主根目录运行，`TEXT_COLOR_SCREENSHOTS`可指定截图目录：

```bash
TEXT_COLOR_SCREENSHOTS=build/document-text-color-screenshots flutter drive --driver packages/cses_document_collab/test_driver/document_text_color_driver.dart --target packages/cses_document_collab/integration_test/document_text_color_test.dart -d ANDROID_DEVICE_ID --no-pub --keep-app-running
```

必须保留`--keep-app-running`，结束后用普通Demo APK执行`adb install -r`覆盖恢复，保留用户数据。截图和结果见[2026-10-21验收记录](../../docs/verification/default-text-color-device-20261021/default-text-color-device-20261021.json)。页面背景及根字色同步不属于本次验收。

### 普通文本段Tab缩进（BlockCraft 0.11.21）

普通段落、H1～H9和引用读取桌面`props.depth`，每级增加32逻辑像素的左侧布局偏移，并减少相同排版宽度；字号不改变。布局按钮与硬件Tab/Shift+Tab写同一字段级事务，保留文字、标题级别和选区；使用稳定块身份支持远端重排后的撤销。新增缩进最多8级，首目标不能超过前一兄弟深度+1，多选任一项达8级则整次增加不写入；旧的超深数据原样展示，可逐级减少。

代码Tab和表格键盘导航保留各自规则。列表沿用已有独立0～6级操作，普通文本与列表混选、跨父容器范围不开放这次文本缩进命令，未把它们标成通用8级Tab已完成。验证覆盖`test/paragraph_indent_test.dart`、完整页面字号/布局回归，以及真实FRB/SQLite的8级保存与历史。下方设备命令同时验证普通段落、标题、引用的0/1/2级位置与剩余宽度。

### 标题字号与分散对齐回归（BlockCraft 0.11.21）

标题与分散对齐共用段落/行内字号规则。`test/heading_typography_test.dart` 直接核对完整页面 `RenderParagraph` 的逐字符最终字号，覆盖五种对齐、段落depth偏移及剩余宽度、真实换行、混排链接、空标题和编辑/预览切换。期望数据从发布包生成，同时输出 JSON 与供真机编译的 Dart 常量，不读取手机上的宿主文件路径：

```bash
node packages/cses_document_collab/tool/generate_heading_typography_oracle.mjs /path/to/extracted/blockcraft-0.11.21/package
flutter drive --driver packages/cses_document_collab/test_driver/integration_test.dart --target packages/cses_document_collab/integration_test/heading_typography_test.dart -d ANDROID_DEVICE_ID --no-pub --keep-app-running
```

设备用例保留真机实际视口并检查移动选区服务；使用临时测试正文，不登录或访问正式文档。运行后按上文约定重新构建普通 Demo，并以 `adb install -r` 覆盖恢复，保留既有应用数据。代码块不附加段落专用历史标记；弹窗退出恢复选区时只临时抑制划词浮栏，归还原选区附加信息，后续用户划词仍可显示菜单。

### 三项格式修复与划词真机验证

`integration_test/editor_review_fixes_test.dart` 在Android设备运行发布字号对照与划词回归，另通过真实页面输入连接验证远端清除/替换默认格式后的实际输入和撤销。包含本地类型转换后继续格式化、远端变化保护，以及长按菜单、文字链接、选中文字转行内公式。使用隔离测试正文，不初始化账号或原生协同数据库；IME及触摸事件由测试注入，不替代人工输入法验收。

```bash
flutter drive --driver packages/cses_document_collab/test_driver/integration_test.dart --target packages/cses_document_collab/integration_test/editor_review_fixes_test.dart -d ANDROID_DEVICE_ID --no-pub --keep-app-running
```

安装前可在应用停止后保留私有数据备份与文件校验值；验证后重新构建普通Demo，以`adb install -r`覆盖安装，禁止卸载或清数据。核对已有偏好与协同SQLite文件未丢失或改变，再启动正常入口；Flutter调试内核、资源时间戳与安装标记不属于用户数据。执行结果与设备范围见[真机验证记录](../../docs/verification/editor-review-fixes-device-20261016/editor-review-fixes-device-20261016.json)。

### BlockCraft 0.11.20 段落默认格式与下一段

正文段落/标题、三类列表和引用支持 `textDefaults` 与 `nextParagraphStyle`。空段落 Aa 格式、整段格式和删空后的共同格式与正文同事务保存；字体/字号/字距随输入往返，链接和业务身份不会成为段落默认值。布局面板可选择下一段按默认规则、延续样式或回正文；段中保留样式，段尾标题/引用默认回正文并清理字符及布局覆盖。Undo/Redo 同时恢复本地输入格式，空段落重开后继续使用共享默认格式。

0.11.21 后续核对补齐三处边界：远端清除/替换空段默认格式会清除本机继承的旧字样、字号、字体、颜色和字距，本地明确选择的输入格式仍优先，主动导航后重新继承；划词格式面板接续自身类型转换与列表退回正文后的稳定选区，远端改字、改类型、删除或撤权仍使旧选区失效；旧CSS字号按发布版去首尾空白、不区分单位大小写，并统一像素/倍率范围、精度及新旧属性优先级。

回归包含远端默认值更新后的实际输入与撤销、连续类型转换后继续格式化，以及发布函数生成的旧字号对照数据；完整页面在五种对齐和编辑/预览切换中检查最终渲染字号。验证结果与未覆盖范围见[修复记录](../../docs/verification/selection-format-review-fixes-20261016/selection-format-review-fixes-0.11.21-20261016.json)。

对应发布产物的对照数据可在仓库根目录重新生成：

```bash
node packages/cses_document_collab/tool/generate_paragraph_oracle.mjs /path/to/extracted/blockcraft-0.11.20/package
```

本轮包含真实 FRB/SQLite 与 Android 集成验证；Android IME 事件由测试连接注入。字体依平台回退，完整字体/段间距设置、0.11.20 的通用 8 级 Tab 规则、iOS 和在线桌面互操作仍待补齐，详见仓库 `docs/block-adaptation.md`。

### 附件卡片布局

附件使用浅底边框卡片，左侧显示按文件类型配色的图标，右侧突出文件名（最多两行）和类型/大小。文件名缺失时使用链接中的文件名，仍为空时显示“未命名附件”；大小按B、KB、MB、GB、TB显示，0字节显示0 B，缺失或无效大小显示“大小未知”。窄屏和大字号下允许元信息换行，空间极窄时图标与信息上下排列。打开、修改、删除和下方插入仍统一在更多菜单中，不改共享属性。

## 内容块锁定

正式文档通过公共更多面板加锁/解锁，锁定内容仍可查看、选择与复制，其他未锁块可继续编辑。锁使用桌面同源`meta.lock`用户ID及可选`lockKind: template`，由整棵原生块图派生祖先继承与子树保护；正文、属性、结构和历史事务整体预检，包含隐藏题注或表格子块。菜单/编辑草稿在锁变化后失效，即使随后解锁也不能提交旧草稿。锁切换使用独立原生命令先写SQLite再推进Doc与同步，不进入正文撤销栈。

普通锁本人可解锁，其他用户及模板锁需要宿主同步授权；缺省拒绝额外授权。Demo按桌面同源文档角色`role >= 800`授权，业务角色由宿主加载并持有。普通锁显示锁标，模板锁与继承锁不重复装饰；公共卡片锁在右上角外沿独立绘制，正文仍保持圆角裁切。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

CollabHostServices lockServices(Map<String, int> rolesByDocument) =>
    CollabHostServices(
      canUnlockBlock: (lock) => (rolesByDocument[lock.documentId] ?? 0) >= 800,
    );

Future<void> lockBlock(CollabController controller, String blockId) async {
  await controller.setBlockLocked(blockId, true);
  assert(controller.blockLock(blockId).locked);
}
```

调用方提供当前会话的可信角色映射并维护账号/文档隔离；控制器借用授权函数，不释放宿主资源。接口Future完成表示本机落盘、投影与提交待发送增量，不代表服务端ACK。此策略与桌面一样由可信客户端执行，原始远端增量仍会应用；不替代服务端权限。快照写入对跨锁节点的重排采取保守拒绝，完整拖拽及富文本剪贴板另行适配。Android与实际发布桌面增量/SQLite交换已验证，在线手机到桌面窗口观察、iOS、同时并发及服务端ACK仍待验收；详见仓库`docs/verification/block-lock-corner-20261019/block-lock-20261019.json`。

## 分页符

正式文档支持根级 `page-divider` 无正文块，连续流展示为虚线与“分页符”标记；添加面板提供插入，根级非空块在其后插入、空段落原位替换，并创建后置空段落。范围选区和嵌套位置拒绝插入，不向上寻找根。直接点击整条分页符弹出操作菜单，提供“在下方插入”和“删除分页符”，不显示右侧三个点；后置正文行首退格同样可以删除，删除末块补空段落；插入与删除均支持独立撤销/重做。只读保留标记并隐藏修改入口，打开面板期间撤权或目标删除时拒绝过期动作。

桌面Schema为rootOnly，旧文档中的嵌套分页符、带非法子块或正文的分页符保持只读占位，原数据不迁移。正常块的未知props/meta在其他正文编辑时保留；删除撤销只恢复已投影数据，未投影扩展与审计字段恢复仍待适配。本阶段不提供纸张分页排版、打印/PDF导出或完整分页符剪贴板。Android/iOS与在线桌面联调另行验收，验证范围见根仓库`docs/verification/page-divider-20261018/page-divider-20261018.json`。

发布Schema夹具可从包目录重新生成：

```sh
node tool/generate_page_divider_fixture.mjs /path/to/blockcraft-0.11.21/package /path/to/cses-client
cargo build --manifest-path rust/Cargo.toml
flutter test --no-pub test/collab_page_divider_test.dart test/page_divider_native_integration_test.dart
```

## Mermaid代码绘图

正式文档支持`mermaid`容器与唯一`mermaid-textarea`源码子块；更多插入面板提供“代码绘图”，点击“编辑源码”打开草稿与实时预览。支持根/高亮内插入、更多菜单下方插入与删除、独立撤销/重做、草稿冲突重载及只读/删除保护；取消不写入。源码最多100000 UTF-16单元，写入正式Y.Text，真实FRB与SQLite恢复沿用既有接口，未增加桥接字段。

离线绘图资源位于`assets/mermaid`，MIT许可证随包保留。运行时固定Mermaid11.13.0，版本/哈希见`runtime.json`；更新使用`node tool/sync_mermaid_runtime.mjs /path/to/cses-client`，版本变化须先审查。运行时不使用CDN或外部绘图服务，禁止图表链接、脚本和外部图片；语法错误保留源码及上一张有效图。源码变化去抖，旧渲染及销毁后的回调失效。测试样本可使用`tool/generate_mermaid_fixture.mjs`从0.11.21发布Schema重生成，浏览器验证使用`tool/verify_mermaid_preview.mjs`。

源码面板提供五类“类型”和“模板”：时序、流程、类图、思维导图、时间线，采用桌面发布源码；类型在草稿开头插入语法前缀，模板替换草稿全文。正文与面板均支持仅文本/仅预览/文本与预览，组合视图在手机上下排列；正文源码只读显示，点击编辑源码打开完整编辑面板。新建面板默认组合视图；取消不写入，保存将源码与主动选择的mode作为一个可撤销事务提交。正文切换视图是独立可撤销事务。

共享mode沿用`props.mode=text/graph/default`，由现有CollabResource单字段补丁承载，没有新增FRB签名。缺失/null/未知mode仅在展示时回落为组合视图，普通源码编辑不归一化；旧调用未指定插入视图时仍默认graph。远端mode变化也会使打开的草稿冲突并清除过期历史；重新加载同时更新源码和模式。2026-10-17已完成真实桌面与Android现有时序图三种mode的双向在线联调，共6项通过；最终恢复原text模式，完整源码Delta/属性及树结构保持，仅绘图修改时间更新，见根仓库`docs/verification/mermaid-20261017/mermaid-view-sync-20261017.json`。不代表真实断网、同时并发、iOS或服务端持久化ACK通过。

本阶段仍部分支持：不提供可视化节点/标签编辑、全屏缩放、SVG导出或Markdown导入。未绑定外部原生历史的编辑器中，远端源码/格式/mode或含绘图文档的结构变化清空路径历史与选区；普通非结构正文属性更新保持历史。`CollabController` 的原生历史模式保留个人历史，由最新投影后的相对书签决定恢复或清除选区。删除撤销恢复投影内容/身份和有效mode，不保证未投影属性、未知/非法模式或审计数据恢复。异常结构保持整棵占位。完整验证见根仓库`docs/verification/mermaid-20261017/mermaid-options-20261017.json`及`docs/block-adaptation.md`。

## 会议 KR 列表

正式 `kr-list` 只保存会议引用，列表通过可选 `CollabHostServices.kr` 查询端口加载。宿主实现 `CollabKrService.loadTopics(meetingId)` 和 `loadMore(meetingId, topicId, offset)`，负责认证、会议权限及请求资源；未配置时显示提示，不请求业务接口。Demo使用桌面同源的已完成KR主题和每页十条结果，真实接口仍需联调验收。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

CollabHostServices krServices(CollabKrService service) =>
    CollabHostServices(kr: service);
```

会议卡片更多菜单提供“收集 KR”，在其后插入列表引用；列表可分页、重试及转为未勾选待办。转换有完整作者身份时插入用户提及，否则仅插入KR文字。引用与待办支持独立撤销重做，业务KR不随引用删除。加载结果、分页及作者头像不写入共享文档，换会议/宿主、卸载后迟到结果失效；端口由宿主持有，编辑器不释放它。实时刷新、会议标题、长列表虚拟化、专用富文本剪贴板/导出、iOS及在线双端仍待同步或验收。

KR前三名图标可由宿主一次提供三个Widget；未配置时显示金银铜色加粗数字1/2/3，不加载图片，第四名起保持普通数字。图标显示在20×20逻辑像素内，外部资源由宿主负责。

```dart
import 'package:flutter/widgets.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

const rankServices = CollabHostServices(krRankIcons: (
  first: Text('🥇'), second: Text('🥈'), third: Text('🥉'),
));
```

## Rust 历史与 Flutter 撤销/重做

`CollabController` 初始化真实原生文档后，自动将 AppFlowy 的撤销/重做按钮和快捷键委托给 Rust。远端正文投影不清空当前用户的原生历史；本地新增编辑清空 redo，远端或系统写入不进入个人历史。正式文档和 SQLite 本地草稿共用这一入口；纯内存 `LocalEditorController` 保留原来的本地历史，不依赖原生协同。

```dart
import 'package:cses_document_collab/cses_document_collab.dart';

Future<void> editDraft(String databasePath) async {
  final controller = CollabController.localDraft(databasePath: databasePath);
  try {
    await controller.initialize();
    // 展示 CollaborativeEditorPage(collab: controller) 后，按钮和快捷键自动接入。
    if (controller.canUndo) await controller.undo();
    if (controller.canRedo) await controller.redo();
  } finally {
    // 实际页面须先退出，再关闭其借用的控制器。
    await controller.close();
  }
}
```

FRB 使用 2.13.0 重新生成桥接；原有块快照适配、协同会话及 V1 update 格式继续复用。Rust 正式引擎使用随包隔离的 Yrs 0.27.4 路径依赖 `rust/vendor/yrs-history`，增加独立候选检查点和只读相对位置解析；上游原生撤销、编码和网络算法不变，来源及改动见该目录的 `UPSTREAM.json`、`LOCAL_CHANGES.md`。

每个 AppFlowy 事务对应一个原生历史组，最多保留 200 组，不跨事务按时间合并。历史仅限当前打开会话；重启恢复 SQLite 正文，不恢复个人撤销栈。Undo/Redo 在候选 Doc 执行，重新检查宿主编辑权限、锁及受影响子树、结构和表格规则；SQLite 写入及 COMMIT 成功后才替换权威正文/历史，再投影到 Flutter。拒绝或落盘失败保留原正文和栈，可解除限制后重试。待删除子树含远端贡献时拒绝冲突，避免间接删除他人内容。

选区随原生 StackItem 保存稳定块 ID 和 UTF-16 相对位置；逆向范围保留方向。正文完成最新投影后用当前路径恢复，支持远端插字与重排；端点被删除时清除选区。书签仅用于个人会话，不写入共享正文、网络或数据库。历史和投影期间暂缓输入，不切入预览或主动关闭键盘。此阶段没有实现跨事务 IME 合组、专门的视口滚动/键盘唤起、整块/表格多单元格范围恢复，或跨启动历史。

暂缓本地事务使用 `EditorState.localTransactionsPaused`，与 `editable` 的权限/预览状态分开；只读页面仍可接收权威投影。原生模式不发布表格/绘图回放过程中的旧路径选区，最终一次恢复相对选区，保持已有输入连接；用户已收起的键盘保持关闭。普通远端正文更新不触发选人、会议或编辑草稿的永久撤权；真实权限撤销、目标变化和关闭仍按原有契约作废迟到结果。异步输入还核对权限/投影与输入连接代次，主动收起键盘后不继续处理旧连接的等待回调。

空草稿段落的文字根在订阅历史前注册；若原生检测到正文有变化却没有捕获历史组，会在落盘前拒绝，保留权威正文与历史。表格删除保护使用可见一侧的内容指纹，支持删行、删列和整表的反复撤销/重做，同时继续拒绝删除含远端新增贡献的子树。完整握手后的自动编号修复只在可编辑且非预览时执行，不进入个人历史。

在包目录验证：

```sh
cargo test --manifest-path rust/Cargo.toml --features history-prototype
cargo build --manifest-path rust/Cargo.toml
flutter test --no-pub test/native_history_editor_test.dart test/collab_native_selection_test.dart test/native_history_review_regression_test.dart
```

独立 Rust 原型仍以 `history-prototype` feature 供实验/回归使用，不是 Flutter 的指令实现。其 root/callout 结构命令限制与正式引擎完整适配范围分开；原型不要与运行中的正式引擎共用实验数据库。当前审查修复与验证见[5项修复记录](../../docs/verification/selective-undo-prototype-20261022/review-fixes.md)，接入实现见[第三阶段](../../docs/verification/selective-undo-prototype-20261022/frb-editor-history.md)，此前行为见[第二阶段](../../docs/verification/selective-undo-prototype-20261022/structure-format-locks.md)和[第一阶段](../../docs/verification/selective-undo-prototype-20261022/report.md)。
