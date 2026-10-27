# packages 与 cses.saas 兼容核对

核对日期：2026-10-22。对象为当前工作区的 `仓库根 package`、`packages/appflowy_editor`，以及 `/workspace/cses/cses.saas`（实际指向 `/Users/shichunlei/workspace/cses/cses.saas`）。包括已有未提交的新建文档改动，不以 HEAD 代替当前源码。未修改 SaaS、Common、桌面源码或依赖。

## 结论

包已经具备适合 SaaS 使用的依赖方向、公开入口、宿主注入和基础运行环境；SaaS 的完整依赖约束加入包后可以解析，公共入口及现有 Common 网关适配器可以通过静态检查。

但尚未完成 SaaS 实际接入，也没有达到现有文档页面与桌面文档能力的完整匹配。应按“可开始正式集成的包基础”使用，不能按“直接替换现有页面即可交付”验收。依赖解析、数据交换、业务接入、交互等价和最终 App 构建是不同层次的证据。

## 已匹配的基础

| 项目 | 核对结果与边界 |
|---|---|
| SDK | SaaS、协同包及 AppFlowy fork 均要求 Dart >=3.12、Flutter >=3.44。本次使用 Flutter 3.44.9 / Dart 3.12.2。 |
| 依赖约束 | 在临时目录复制 SaaS pubspec，将其本地 path 转成绝对路径，再增加协同包，`flutter pub get` 成功。另以原 SaaS 锁文件为起点执行离线解析也成功；保留 dio 5.11.1、flutter_svg 2.3.0、intl 0.20.2、file_picker 13.1.0、webview_flutter 4.14.1，增加 FRB 2.13.0 和两包，并将 video_player 2.11.1 升至 2.14.1 等。Pub 报告 36 项变化包含临时目录 path 改写，不能解读为 36 项版本升级。未修改真实 SaaS 锁文件。 |
| 依赖方向 | 两包 lib 没有导入 Demo、cses_saas 或 cses_common。Common HTTP、WebSocket、OSS 适配留在 Demo，包使用端口。 |
| 公开 API | `cses_document_collab.dart` 暴露控制器、编辑页、配置、宿主服务、网关和正式空正文准备能力；宿主不需要访问 Rust/FRB 内部 API。隔离消费者公共入口及网关静态检查通过。 |
| Common 接口 | 现有网关使用的 `registerListeners`、`unregisterListeners`、公开 lock、SocketSubscription、连接事件和发送接口仍存在，复制到 SaaS 依赖图后静态检查通过。只证明接口可用，未证明共享主连接的并发/重连时序。 |
| 协同主协议 | Document/channel、docId/topic、instance、collabJoin/Sync/Update/Awareness/Leave、Base64 V1 update 与 state vector 的主体形式一致。失败状态处理存在下述差异。 |
| 缓存与资源 | 正式文档缓存分区包含服务端、企业、用户、docId，不把 cookie 放入键；连接归宿主，控制器 close 释放文档资源。 |
| 最终 App 基础平台 | 实际消费 SaaS 的 cses.jqdl Android 配置为 compileSdk 36、minSdk 26、NDK 28.2；iOS Runner 主配置为 14.0，满足本包声明的 Android API24+/iOS14+基础要求。尚未在加入本包的该 App 中构建验收。 |

## 接入前必须处理的差距

### 1. SaaS 当前没有消费本包，详情页仍是 H5

`cses.saas/pubspec.yaml` 没有 cses_document_collab 或 appflowy_editor 依赖，lib/test 全局检索也没有本包控制器、网关或正文视图调用。`lib/modules/doc/routes/pages.dart` 的 cloudDocDetail 指向 `CloudDocDetailPage`；其 `presentation/preview/page.dart` 实际呈现 `WebViewWidget`。

因此本项目 Demo 的打开、重连、编辑与新建验证不会自动覆盖 SaaS。需要在 SaaS doc 模块的 Infrastructure 实现端口，在 Application 管理权限和文档会话，在 Binding/Page 装配与展示；复用现有 Repository、UseCase、Navigator 和事件，不把 Demo 全局流程直接移入包。

### 2. 服务端明确报告同步失败时，移动端状态没有跟随失败

`lib/src/sync/cses_doc_collaboration_session.dart` 的 collabSyncStatus 分支对任何 body 都只调用 `onStateChanged(_state, 'sync-status-received', null)`。若会话已经 ready，收到 `{synced:false}` 后仍维持 ready。

对照 `cses-client/packages/docs/src/realtime/docs-collaboration-session.ts`：该分支检查 synced 类型，false 触发失败恢复。两边均正确避免把 true 当作握手完成或持久化 ACK，但“不是 ACK”不意味着可以忽略明确的失败。

影响：宿主可能在服务端报告处理失败后继续显示在线。接入前应明确 false/无效状态的失败语义和恢复边界，并增加 ready 后 false、握手中 false、无效类型及关闭后迟到消息回归。本轮为源码证据，未伪造真实服务错误。

### 3. SaaS 权限模型尚未完整映射

SaaS `AbilityEntity` 包含 access、cdp、comment、modify 等能力，`DocCollaboratorRole` 区分 reader/editor/manager/owner。包的正式配置主要接受 editable，额外块解锁由宿主回调提供；这些端口不会自动消费 SaaS 权限。

尤其包的宿主契约没有 cdp/复制下载能力入口。`collab_mobile_selection_menu.dart` 在有选区时提供复制，`collab_code_block.dart` 直接写剪贴板，附件打开使用外部 URL 启动；均没有 SaaS 的 cdp 检查。SaaS 权限实体明确将 cdp 定义为复制/打印/下载，现有更多菜单也使用它控制创建副本。若产品要求原生正文同样执行这项权限，当前契约不足，不能仅通过 `setEditable(false)` 代替复制下载控制。

需要分别确定访问拒绝、正文编辑、元数据、复制下载、评论及块解锁的规则和动态撤权路径。账号/企业切换必须阻断旧异步结果，并等待旧文档释放；不能把启动时角色永久当作授权。

### 4. 进程单 Doc 与 SaaS 路由栈需要协调

`CollabRuntime.acquire` 明确拒绝第二个独立文档控制器，错误为 COLLAB_DOCUMENT_IN_USE。SaaS `DocNavigator.goCloudDocDetailPage` 默认通过 Get.toNamed 压栈，允许从当前业务页面继续打开另一篇文档。

将每个文档路由直接配置为“创建一个控制器，页面退出再 dispose”会让栈中旧文档继续占用引擎。必须选择单活动会话、切换前 await close、返回时恢复旧文档，或明确限制路由行为；GetX 同步 onClose 不能代替等待异步关闭。多个视图借用同一个控制器也不等于支持多个不同 docId。

### 5. 直接替换会丢失当前 SaaS 业务行为

| 当前 SaaS 能力 | 本包及 Demo 现状 | 集成要求 |
|---|---|---|
| 图片预览 | 本包有 onImageTap；Demo 只日志和提示 | 绑定 SaaS 的 showImagesViewer，并等待预览关闭。 |
| 附件打开 | SaaS 使用 ResourcesNavigator；本包直接 launchUrl externalApplication，无附件专用宿主回调 | 增加资源打开契约，保留 ResourceBean、bucket/type、鉴权和下载策略。 |
| 划词评论 | SaaS 已有 groupId/selectedText 事件和原生评论线程；本包仅有全文评论端口，没有同等的选区锚点/线程端口 | 若替换阅读页需补齐；不能用全文评论冒充划词评论。 |
| 全文点赞/评论 | 本包已有加载/写入回调；Demo 点赞仅内存切换，评论仅提示 | 接入已有 UseCase、服务端确认结果和 DocBehavior 事件。 |
| 会议、任务、用户、文档详情 | 本包已有提及/会议回调与部分数据加载；Demo 点击仍提示 | 通过各业务模块公开入口调用真实导航及选择器。 |
| 更多菜单、分享、收藏、移动、删除、权限、标签 | SaaS 已有 Coordinator；本包完整页不包含这些 SaaS 路由动作 | 保留 SaaS 页面外壳或扩展组合方式，复用原服务。 |
| 正式新建 | 本包已提供 DocumentBootstrapper/PreparedDocument；HTTP和恢复协调器仍在 Demo document_creation | 在 SaaS doc 业务层接入正式创建/权限/目录/恢复链路，复用同一 CRDT 来源，真实服务验收。 |
| URL 入口 | SaaS 可只传完整 URL，且校验当前环境 | 原生打开前解析并校验正式 docId；保留跨环境拒绝及非正文资源分流。 |

### 6. 网关具备接口兼容，但尚不是 SaaS 的生产装配

`CommonCsesCollabGateway` 仍位于根 Demo，文档明确限制为单会话；它通过 Common 的 async void 注册加公开 lock 屏障等待，并由自己的连接流恢复 Document subscribe。这种方式当前能编译，不能据此宣称所有共享连接场景已验收。

SaaS 正式适配必须固定订阅恢复责任，保证 Document subscribe 在 collabJoin 之前，不重复进入 Common 离线队列；pageId/instance 隔离，在线和离线退出都正确注销。禁止把 Demo 的登录、connect/recover/close 主连接所有权直接搬进文档路由，以免影响会议、直播等现有订阅。

### 7. 桌面数据兼容仍是有限集合

按现有适配表：41 种块中 13 已适配、14 部分支持、1 结构支持、13 未适配。shape、text-box、word-art、columns、render-unit、天气/日期/人员卡片等不能按完整可编辑文档验收。未知数据保留和占位保护属于安全降级。

Rust 对非空 `bc:revisions` 明确把整篇设置为只读。桌面字体数值字重 `s:fontWeight` 在 .24/.27 发布实现中已存在，移动正文样式仍主要读取 bold；格式补丁字段清单也未纳入数值字重。因此视觉、输入继承和主动格式化的语义仍需同步。剪贴板、完整字体/段落排版、部分缩进、复杂对象与修订也不能由包版本号推定一致。

### 8. 交付与原生构建仍须在最终 App 验证

协同包依赖 `../appflowy_editor`，两个目录需要一起交付，或由最终宿主显式覆盖到同一 fork；不能只复制 cses_document_collab，也不能用 pub.dev 同版本号的 AppFlowy 替代本地补丁。两包均 publish_to:none，目前没有独立发布物方案。

iOS SPM 使用未跟踪的本地 XCFramework，解析前需要执行包内 build_rust_ios.sh；Android 通过 Cargokit 构建。最终 cses.jqdl 的 SDK 下限满足基础要求，但本次没有修改该 App 依赖，也没有执行其 Android/iOS 打包与设备验收。包级测试不等于最终 App 原生链接、签名、ABI 和插件共存已通过。

## BlockCraft 本轮核对

- 通过桌面 `.npmrc` 中 `@ccc:registry=http://npm.runtongqiuben.com/` 实时查询，latest 为 0.11.27。
- 桌面根声明及 yarn.lock 为 0.11.24，实际安装 0.11.21；项目使用 Yarn 1.22.22，历史 pnpm-lock.yaml 仍为 0.2.78，不能用它代替当前 Yarn 锁定结论。
- 下载 0.11.24 与 0.11.27 发布产物，按注册表 dist.integrity 校验 SHA-512；读取安装版及发布版随包 L0、数据文档、MIGRATIONS 和相关实际实现。迁移文档中的“未发布”标题不能覆盖已经存在于产物的实现事实。
- 三版 RootBlockSchema 和 ParagraphBlockSchema 声明片段 SHA-256 分别一致，见 schema-hashes.json。仅证明这些片段一致，不表示所有 Schema、输入、菜单、历史和协同均相同。
- .24/.27 包含只读正文链接单击导航及数值字重等安装版之后的差异；.27 另增加右键文本/段落设置和 @cses/ui 4.37.3 peer。移动端相应行为及原有差异继续标为待同步/待验收；未升级桌面或移动端依赖。

## 建议集成顺序

1. 先落实 SaaS 单活动文档会话、共享 Gateway、账号隔离和权限适配，修复明确同步失败处理；两包以固定来源一起交付。
2. 在原 doc 路由下接入有限块集合的原生编辑页，保留无法完整表示的文档分流策略；先确定现有阅读功能必须保留的范围。
3. 复用业务 UseCase/Navigator 接通头部、上传、预览、提及、点赞/评论与更多动作；需要保持划词评论和附件资源页时扩展对应宿主契约。
4. 接入正式创建和恢复流程，在真实服务验证 HTTP 快照与协同初始化来源；最后在最终 App 验证 Android/iOS、双端、断网重连、切账号和权限变化。

## 本轮验证

| 验证 | 本轮结果 |
|---|---|
| SaaS 完整依赖约束，新解析 | 成功，见 [日志](fresh-dependency-resolution.txt)。 |
| SaaS 现有锁文件加包，离线解析 | 成功，见 [日志](existing-lock-resolution.txt)；最终 App 自己的锁图还需正式接入后检查。 |
| 隔离消费者公开入口静态检查 | 无问题，见 [日志](public-api-analysis.txt)。 |
| 隔离消费者复制现有 Common 网关后检查 | 无问题，见 [日志](common-gateway-analysis.txt)。 |
| 包内 sync/controller/model 静态检查 | 无问题，见 [日志](package-analysis.txt)。 |
| 协同会话、头部、互动、PreparedDocument | 4 个文件，22 项全部通过，见 [日志](package-target-tests.txt)。 |
| 真实 FRB/SQLite 与 .27 发布 Schema/Yjs 交换 | 3 项全部通过，无跳过，见 [日志](native-interop-node24.txt)。包含 CRDT 身份复用、单控制器占用保护、桌面 Yjs 接续编辑及 SQLite 重开。 |
| diff 检查 | `git diff --check` 通过；本轮仅新增本报告/证据和适配表核对记录，没有修改业务源码。 |

原生互通首轮未指定 Node 路径，Flutter 子进程实际使用的旧 Node 缺少 `node:assert/strict`，导致 1 项环境失败、2 项通过；保留[初次日志](native-interop-initial-node-failure.txt)。随后按 README 显式指定 Node 24.14.0 重跑全部 3 项通过，未修改测试或降低断言。

包目录复现：

```sh
flutter analyze --no-pub lib/src/sync lib/src/controller lib/src/model
flutter test --no-pub test/cses_doc_collaboration_session_test.dart test/document_metadata_controller_test.dart test/document_feedback_controller_test.dart test/prepared_document_test.dart
flutter test --no-pub \
  --dart-define=BOOTSTRAP_DESKTOP_ROOT=/Users/shichunlei/workspace/cses-client \
  --dart-define=BOOTSTRAP_PACKAGE_ROOT=/tmp/cses-compat-lWilaO/blockcraft-0.11.27/package \
  --dart-define=BOOTSTRAP_NODE_EXECUTABLE=/Users/shichunlei/.nvm/versions/node/v24.14.0/bin/node \
  test/document_bootstrapper_native_test.dart
```

临时发布包目录仅为本轮工具产物；后续复现需按桌面配置仓库重新下载并校验对应版本。隔离消费者由 SaaS pubspec 的本地 path 改为绝对路径、追加当前协同包 path 得到；现有锁图验证另复制原 SaaS pubspec.lock，不修改源仓库。

验证范围限于源码核对、隔离依赖/静态检查、包内定向回归和桌面数据层交换。不包括全包测试、完整 App 构建、真实 SaaS 路由、业务 HTTP、服务端持久化 ACK、真实桌面窗口或手机联调。同步失败状态差异、cdp/评论/资源等业务缺口仍按源码发现保留，不因这些定向测试通过而关闭。
