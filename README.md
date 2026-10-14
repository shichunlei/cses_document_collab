# CSES Mobile Collab Demo

一个独立运行的 Flutter + Rust/Yrs 离线协同实验。协同核心位于 `packages/cses_document_collab`；根 App 装配登录、Common 主连接、上传与缓存路径。

桌面块的完整移动端适配进度见 [块适配表](docs/block-adaptation.md)。每完成一个块的适配，都须同步更新该表的状态、支持范围及验证记录。

## 已实现

- AppFlowy Editor 6.2 块编辑界面和连接状态
- 独立全屏 `CollaborativeEditorPage`，与 Demo 的连接配置页面解耦
- `CollaborativeEditorPage` 支持编辑/预览切换；预览时收起键盘和工具栏并禁止文档修改
- 飞书文档风格的固定头部：默认头图、可添加/替换/移除封面，以及大号可编辑文档标题
- 基于键盘 Insets 的稳定移动快捷栏，T/Aa/块布局二级菜单展开时不收起键盘
- 参考移动文档产品的“添加”底部面板，支持 H1～H9、两种列表、Todo、引用、高亮块、链接、图片和视频
- T 菜单从 H1～H3 开始按需逐级展开到 H9，并包含列表、Todo、代码块和引用；三种列表互换保留层级、正文格式及光标/选区
- Aa 菜单包含加粗、斜体、下划线、删除线、行内代码、文字颜色、上标和下标
- Aa 行内格式在当前段落内持续生效；再次点击当前格式或切换段落时取消
- 块布局菜单支持整块背景色、引用块左侧线条颜色（与桌面 `props.backColor` / `props.borderColor` 双向同步，支持清除及撤销），左/中/右/两端/分散对齐和三种列表的 0～6 级缩进；最外层减少缩进转普通段落，保留光标/选区
- 行内加粗、斜体、下划线、删除线、行内代码、文字颜色、上标和下标使用 Y.Text 原生 attributes 协同
- Todo 新建、段落/Todo 转换以及勾选状态实时协同
- 代码块使用白底细边框和浅色标题栏，支持修改名称、搜索选择语言、折叠/展开、复制完整源码和语法高亮；`props.blockName` / `props.lang` / `props.collapse` 与桌面同步并支持逐字段撤销，预览折叠只影响本机，着色不写入 Y.Text
- 高亮块兼容桌面 `callout` 容器；点击前方表情打开表情弹窗，可更换/移除、自定义表情；点击右侧设置打开独立颜色弹窗，可修改背景色和边框色。文字颜色使用键盘上方 Aa 菜单设置。支持逐项撤销和离线恢复，块内多段正文保持独立编辑和协同
- AppBar 撤销/重做；远端 transaction 不进入本机 UndoManager
- AppFlowy transaction 与 Rust/Yrs 块级 Schema 适配层：离线草稿沿用 Demo 模型，CSES 文档使用正式 BlockCraft 模型
- `paragraph`、`heading_1`～`heading_9`、`bulleted_list`、
  `numbered_list`、`todo_list`、`quote`、`code`、`callout`、`link`、`image`、`video`、
  `document_cover`、`document_title`
  的类型、文本/URL 和受支持属性同步
- 链接块可打开系统浏览器，正式图片展示比例尺寸和题注，离线图片复用 AppFlowy 原生渲染；视频支持内嵌播放
- 光标位于资源块后方文本块的起始位置时，软键盘或硬件键盘退格可删除链接、图片、视频块并保留当前段落
- 稳定 blockId；AppFlowy 拆分或转换节点后仍保持协同身份
- `Y.Array` 块顺序、`Y.Map` 块类型、每块独立 `Y.Text`
- 本地 AppFlowy transaction、远端 transaction 防回环
- `flutter_rust_bridge` 调用手机端 Rust
- Rust/Yrs 提供原始 V1 update、状态向量和 Awareness，CSES 适配层使用 Base64 JSON 文本信封
- Demo 宿主引用 `../cses/cses.common`，复用 Dio HTTP、登录上下文、hello、主连接心跳、重连及精确三级路由
- `subscribe → collabJoin → collabSync → collabUpdate` 双向差量交换，20 秒主动补偿
- 本机 Awareness 10 秒提升时钟上报，显示其他编辑器数量；尚未绑定光标和选区
- 在线协同只使用 CSES 主连接，通过 Common 收发 JSON 协议，不提供独立 WS 传输或本地测试服务
- `OffsetKind::Utf16`，与 Dart/Yjs 的文本下标一致
- `gc: false` 对应的 `skip_gc: true`
- SQLite 增量 Update 日志，应用重启后离线恢复
- 同一正式测试 docId、不同 instance 的手机间实时同步
- 旧版 `cses_demo_text` SQLite 数据以零文本复制方式挂载为 paragraph 块

独立离线草稿使用手机 Demo 自有的块 Schema：

```text
cses_mobile_block_order          Y.Array<blockId>
cses_mobile_block_meta           Y.Map<blockId, blockType>
cses_mobile_block_checked        Y.Map<blockId, bool>
cses_mobile_block_align          Y.Map<blockId, left|center|right>
cses_mobile_block_indent         Y.Map<blockId, 0..6>
cses_mobile_block_text:<blockId> Y.Text（文本块含行内 attributes；链接/图片/视频块存 URL）
```

封面与标题也复用上述块结构：`document_cover` 的 Y.Text 保存可选图片 URL，
`document_title` 的 Y.Text 保存标题文字。旧文档首次加载时会使用确定性 blockId
自动补齐头部；默认封面为 README 当前版本配置的百度图片链接。用户主动移除后保留空 URL，
后续加载不会再次覆盖为默认图。

CSES 文档通过 `packages/cses_document_collab/rust/src/api/blockcraft.rs` 直接读写正式共享类型：

```text
blocks                         Y.Map<blockId, Y.Map>
  block.id/flavour/nodeType    身份与类型
  block.props/meta             Y.Map；保留未知字段和审计数据
  block.children               editable 为 Y.Text；root/block/void 为 Y.Array<blockId>
bc:revisions / bc:revision-decisions / bc:revision-meta  原样保留的修订数据
```

正式段落的 `props.heading` 映射手机 H1～H9，`bullet/ordered/todo/blockquote/code`
映射列表、待办、引用和代码，图片使用 `props.src`、视频使用 `props.url`。Todo 的 checked 写入数值 0/1，
正文对齐使用 `textAlign`，图片对齐使用 `align`，缩进使用 `depth`。富文本使用 `a:bold/italic/underline/strike/code/sup/sub`
与 `s:color/background`，手机 ARGB 颜色写回 CSS。格式只更新发生变化的区间与受支持键，
已有链接、字体和其他未知行内属性不会被整块清空。新增块沿用正式共享类型，既有块不重建。

远端更新先在探测 Doc 验证根身份和块字段类型，再进入权威 Doc/SQLite。
未知 flavour 和未适配结构显示一个空的只读占位块，文案为“未适配的块（不可编辑）”；
不展开未知容器的后代，原始共享内容、属性和父子关系保留；其他已识别块仍可编辑、撤销及同步。
未知块不会触发整篇只读；AppFlowy 与 Rust 都拒绝修改、转换或删除占位块，含占位的父容器也不能整体删除，避免丢失未知内容。
行内对象、锁定块、修订记录和未知顶层根继续使用整篇只读保护。
结构重复/循环、缺失子块等情况同样限制编辑。正式正文缺少根时等待初始化，
不自动创建根、封面或标题；业务界面空白不代表 Yjs 文档无结构。
只读约束同时在页面输入和 Rust 写事务前检查。手机专属标题、封面和独立链接块
没有隐式正式对应，相关操作会被拒绝并恢复 UI。

## CSES 接入与资源所有权

```text
Demo 登录（Common HTTP → User/ctx）→ DemoDocumentHost → cses_document_collab 公共入口
             ├─ CsesDemoHost → 使用 Common 当前认证的唯一主连接
             ├─ CommonCsesCollabGateway → 包的 Gateway 契约
             ├─ CsesEditorMediaUploadService → 宿主 OSS/文件登记
             └─ CollabController → AppFlowy 投影 ↔ Rust/Yrs ↔ SQLite
```

完整接入契约、资源释放顺序和迁入 SaaS 的步骤见 [协同包接入文档](docs/collab-package-integration.md)；独立包的公共 API 与构建说明见 [包 README](packages/cses_document_collab/README.md)。包不引用 demo、SaaS、Common 或全局登录上下文。

- Android 宿主通过 `com.yundiz/common` 提供设备 ID、CPU 型号及 CPU 信息，复用 CSES Android 的设备处理器契约，使 Common 的 `ctx.updateDeviceInfo()` 可完整初始化；CPU 信息读取失败时使用系统兜底。
- Demo 按 SaaS 账号密码流程先初始化 Common 的 PRE 配置、偏好和设备信息，再通过 `HttpManager` 的共享 Dio 请求 `/User/login`；公共 header 和异常映射均由 Common 提供。固定正式测试文档 ID，不保存密码或登录账户快照。
- 登录成功后由 `CsesAccountLogin` 将完整响应交给 `User().resolveContext(value)`，统一解析身份、企业、权限、媒体站点、域名和 WebSocket 地址，校验通过后才进入文档页。企业选择复用 Common 的组织排序和上次企业偏好；Demo 不再保留响应副本、手动推导企业或覆盖连接地址。页面已销毁的迟到响应不注入上下文；解析/校验失败清理本次用户态，留在登录页重试。
- 登录成功直接通知页面切换，账号与展示名读取 Common 的 `User`，不传递独立会话对象。`DemoDocumentHost` 选择旧 SQLite 路径，在创建控制器时直接使用 `ctx.websocketHost`、`User().companyId`、`User().userId` 和展示名构造 `CollabDocumentConfig`，再注入 Gateway、ID、日志和媒体上传；不再次解析登录或请求 `/User/auth`。包直接打开正式模型，不先打开草稿；离线预览和测试显式设置 `localDraft: true`。
- 文档 ID、服务端、企业、用户和数据库路径只在 `CollabDocumentConfig` 中形成不可变快照；缓存键由协同包统一计算，宿主不保存 Cookie 副本或重复维护缓存算法。切换身份须关闭旧控制器后重新创建。
- WebSocket 地址和默认协议以 Common 解析结果为准。若与历史 Demo 的默认地址不同，按现有地址/企业/用户/文档缓存键进入对应分区，旧缓存仍保留。
- `initialize()` 完成表示本地恢复和回调注册完成；协同 ready/online 只表示客户端差量交换，不是服务端落库回执。
- 页面借用控制器；退出账号先等待包的 close，再由 Demo 宿主关闭主连接，并通过 Common 清理用户态，保留应用级设备信息。即使本地文档初始化失败，退出也会清理已登录身份。返回连接面板仍复用同一控制器。
- Rust 是单文档引擎，包对第二控制器明确拒绝；新文档必须等待旧控制器关闭。
- 包使用宿主编辑授权和模型只读条件。只读握手不补传缓存中的本地变更，恢复授权后再同步。正式部署仍需服务端文档/租户鉴权。
- 权限、文档不存在、非法 schema 停止自动重试；重连和主动补偿维持原协议。上行单次 1 MiB，下行正文 32 MiB，向量/Awareness 64 KiB。
- Common 适配器保留既有 onlyListen 与手动 subscribe 实验边界；同步发送异常可能进入 Common 队列。join/leave/Awareness 的失败重放仍需真实环境验证。
- Common WS 地址不能带既有 query；其 URI 日志可能包含凭证，不能共享原始连接日志。

## 运行

首次构建移动端 Rust 库时安装目标工具链（源码已在包目录中）：

```bash
rustup target add \
  aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
  aarch64-linux-android armv7-linux-androideabi \
  i686-linux-android x86_64-linux-android
```

安装依赖并启动 Flutter：

```bash
flutter pub get
flutter devices
flutter run -d <android-device-id>
# iOS 先生成 SPM 所需的 Rust XCFramework
scripts/ios.sh run -d <ios-device-id>
```

启动后进入用户名、密码登录页，使用 PRE 环境的真实账号登录；不预填账号密码，
不再手动填写 userId、cookieId、companyId 或 WS 地址。登录成功后自动连接固定正式测试文档
`6ac76e5375083c8c9f19cbd3`。文档页可重新连接、清理本机缓存或退出登录。
会话只驻留内存，重启后重新登录；SQLite 正文缓存仍按地址/企业/用户/文档隔离并保留。

两台设备分别登录各自账号，deviceId 自动读取本机标识，测试文档 ID 相同。
instance 自动生成，同一次文档宿主挂载期间保持稳定，重新配置连接时产生新实例。
界面出现 `bidirectional-sync-ready` 后再确认双端编辑；握手超时要核对会话和服务端协议部署，
底层 Socket 打开或收到 hello 不代表文档会话成功。

宿主 Flutter 最低版本为 **3.44.9**，Dart 最低版本为 **3.12.0**；`cses_document_collab` 支持 Flutter 3.44.0 起。
依赖按 Flutter 3.44.9 验证，锁定版本见 `pubspec.lock`。Flutter SDK 固定的依赖与工作区插件的
主版本约束继续由依赖解析器管理。`cses_document_collab` 使用 ffi 2.2.0、ffigen 21.0.0；
ffigen 22/23 的传递依赖要求 meta >=1.19，与该 Flutter SDK 固定的 meta 1.18 不兼容。
FRB 的 Dart 库、Rust 库和代码生成器统一为 2.13.0。修改 Rust API 后使用
`flutter_rust_bridge_codegen` 2.13.0 执行 `flutter_rust_bridge_codegen generate`，再重建原生库。
iOS 最低版本为 14.0。宿主只使用 SPM，不需要 CocoaPods；`packages/cses_document_collab/ios` 提供 SPM 接入。
使用 Flutter 3.44.9 默认启用的 SPM 支持，无需额外配置开关。
Flutter 生成的 `FlutterGeneratedPluginSwiftPackage` 管理插件，Rust 插件通过
`packages/cses_document_collab/ios/cses_document_collab/Package.swift` 引用本地动态 XCFramework。

使用统一入口构建或启动 iOS，确保先更新 Rust 库，再解析 SPM 依赖：
从旧 Pods 工程首次切换时先执行一次 `flutter clean`，避免链接到旧的同名 framework 缓存。

```bash
scripts/ios.sh build ios --debug --no-codesign
scripts/ios.sh run -d <ios-device-id>
# Release / Archive
scripts/ios.sh build ipa --release
```

脚本用 Cargo 增量构建真机 arm64、模拟器 arm64/x86_64，并生成 XCFramework。
Rust 二进制和 `ios/Flutter/ephemeral/` 都不提交；干净检出后必须先通过上述入口生成二进制。
使用 Xcode 前先执行 `scripts/build_rust_ios.sh debug`（归档使用 `release`），再执行
`flutter build ios --debug --config-only` 并打开 `ios/Runner.xcworkspace`。
Rust 源码改变后，直接使用 Xcode 或 `flutter run` 前也需要重新执行 Rust 构建脚本。
iPhone 首次运行需要在 Xcode 中配置开发者签名。

`cses_document_collab` 保留 `.podspec` 和 Cargokit 构建脚本，供其他使用 CocoaPods 的宿主接入；
本宿主不提供 CocoaPods 回退配置。
当前 Android 构建输出位于 `build/app/outputs/flutter-apk/app-debug.apk`。
Rust 或 FRB 桥接声明变化后必须停止运行并完整重新构建安装；热重载/热重启不能替换已加载的原生库。

建议按以下顺序验收当前块级阶段：

1. 手机 A 输入中文、Emoji 和多段 paragraph，手机 B 应实时出现；
2. 独立离线草稿检查默认封面与大号标题；正式文档检查原正文完整加载、没有新增 Demo 头部；
3. 光标进入正文后，确认键盘上方出现 `＋ / T / Aa / 块布局 / 图片 / @`
   快捷栏；
4. 选中文字后点击 `Aa`，验证粗体、斜体、下划线、删除线、行内代码和文字颜色会同步；
5. 点击 `T`，验证 H1～H9 的逐级展开、有序/无序列表、Todo、代码块和引用块；点击 `Aa` 验证上标和下标；Todo 勾选后手机 B 应同步状态；
6. 点击块布局，验证对齐方式与列表缩进在手机 B 同步；
7. 点击 `＋`，验证 H1～H9、两种列表、Todo、引用、链接、图片和视频块同步；
8. 插入链接/图片/视频时填写完整的 HTTP(S) URL；资源块后应自动定位到空正文并弹回键盘；
9. 光标停在资源块后方段落的第 0 位时按退格，资源块应删除、当前段落与键盘应保留，并同步到另一台手机；
10. 空块会原位转换；当前块已有正文时，会在其后插入所选的新块；
11. 点击顶部撤销/重做，操作结果应继续同步到另一台手机；
12. 两台手机在不同块同时输入，最终块顺序、类型、文本和样式应一致；
13. 两台手机在同一块同时输入，Yrs 应合并双方文本；
14. 手机 A 断网后继续新增块、输入、设置格式或勾选 Todo，恢复后应收敛；
15. 杀掉并重启任一客户端，应先从 SQLite 恢复，再与服务器补齐。
16. 未知块和未适配容器显示不可编辑占位，其他已识别块仍可编辑；行内对象、锁或修订保持整篇只读，原始内容和父子关系不变；
17. 拒绝的块操作应恢复 UI；支持的编辑应保留原 blockId、props/meta 未知键、链接与字体属性；
18. 正式文档重连与新打开应使用 blocks 根，不能补传旧 Demo 缓存；同块并发文本和不同格式应收敛。

## 验证

根 App 测试覆盖登录、旧缓存身份、Demo 页面与 Common 本机 WebSocket 联调：

```bash
flutter test test
flutter analyze --no-pub
```

包内测试从包目录执行；先按包 README 配置同一 AppFlowy fork，再构建原生库：

```bash
cd packages/cses_document_collab
flutter pub get
cargo build --manifest-path rust/Cargo.toml
cargo test --manifest-path rust/Cargo.toml
flutter test --no-pub
```

异地引用验证：`packages/cses_document_collab/tool/verify_portable_package.sh packages/appflowy_editor`。

## 与 CSES 桌面端的边界

当前 Demo 使用正式 BlockCraft 的 blocks 根、嵌套块 Map 和原生 Y.Text，支持普通顶层正文及高亮容器内正文双向编辑。
`rust/tests/fixtures/` 保存由 Yjs 13.6.19 编码的脱敏 V1 样本，覆盖富文本、未知 props/meta、
未知容器、行内对象和锁。生成器 `generate.cjs` 接受已安装的 yjs 包路径，避免依赖 Rust 自己生成的样本自证兼容。
原生桥接测试验证业务根 ID 与缓存键分离、编辑以及 SQLite 恢复；旧样本测试缺库时显式跳过；新增控制器抽包门禁缺库直接失败，运行前需先 cargo build。

当前未接入文档业务名称/封面接口、`/doc/document/edit` 的 dirty-block 快照、评论及业务权限。
Awareness 展示用户和在线数，尚未对齐桌面光标/选区契约；不能用 ready 或 SyncStatus 声称业务落库成功。
表格和复杂嵌套布局暂时显示不可编辑占位，其他已识别块仍可编辑；行内对象、锁与修订继续整篇只读，后续按对应语义适配。

当前同步顶层块的类型、顺序、文本/URL、Todo 勾选、对齐和视觉缩进，以及 bold、italic、underline、
strikethrough、inline-code、textColor、backgroundColor、superscript、subscript 行内属性。当前缩进保持扁平块
Schema，仅表现为列表/Todo 的视觉层级，不会生成 AppFlowy 子节点。链接、图片和视频 URL 使用各块现有
bridge 的 text 字段传递；正式图片写入 props.src、视频写入 props.url；图片使用 block 类型，children 为题注 ID 数组，
视频沿用 void 与空 Y.Array；离线 Demo 的
链接/图片/视频使用私有 Y.Text 载荷。正式独立链接块尚不支持，已有行内链接属性保留。
语义嵌套列表、table、Awareness 光标与选区暂时不会同步；
提及、文件、表格等入口仍显示“后续阶段”提示，不会插入 Rust Schema 无法保存的节点。

### 列表键盘交互、正式有序编号与块转换

- 正式 `ordered` 的 `props.order` 为零基序号，0/1/2 分别显示 1/2/3；手机不依赖桌面
  只处理本地结构操作的自动编号插件。Rust 在本地正文/根顺序事务内同时维护编号，再持久化及广播。
- 编号按当前桌面 `OrderedBlockPlugin` 的兄弟扫描规则计算：同层段落不打断编号，返回较浅层
  清除深层计数器；`ordered` 的 `heading` 构成标题边界，正整数 `start` 重开对应计数器。
  缩进仍是扁平块的 `depth`，不是 AppFlowy 嵌套节点。原有 start/ms/continuePrevious 和未知属性保留。
- `collab_list_editing.dart` 在标准字符快捷键之前接管扁平有序/无序/Todo 列表 Enter，软键盘与硬件键盘
  复用同一入口。有正文时通过 AppFlowy 原有文字拆分能力新增同类型同级项，继承 depth、对齐和
  行内格式，不复制原项身份、起始编号或派生投影；有序项的新序号由 Rust 计算。空项 Enter 只退出
  一个 depth，最外层空项再 Enter 转为普通段落；退级后输入文字，下一次 Enter 仍新增同级项。
  判断依据是当前正文和层级，不记录连续按键次数。Shift+Enter、范围选区和真正嵌套节点
  继续交给标准输入链。显式 ms 保持桌面行为，默认标记样式随层级变化。
- Enter 空项与 Backspace 行首共用 `outdentCollabListAtStart`：每次只降一个 depth，最外层
  转普通段落，保留正文、行内格式、对齐和选区路径偏移 0；退级保持 Todo 勾选。
  Backspace 有正文/空项均支持，只接管折叠光标的列表项正文开头，不按屏幕换行位置判断。
  真正嵌套节点、行内文字删除和范围删除继续使用标准输入链；每次退级/转换独立可撤销。
- 工具栏通过同文件的 `changeCollabListIndent` 操作点击时的当前选区，不保存菜单 build 时的
  选区快照。增加缩进对每项加一级、保留显式起点；减少沿用父级接续规则，0 级项转段落。
  有序编号由 Rust 按目标层级重算，Todo 勾选、正文、格式、对齐以及项内光标偏移保持。
  支持正反向范围和块选区；整个选区一个事务/一个撤销步骤，保留选区路径、偏移、方向和类型。
  增加时任一项到达 6 级则整体禁用；选区含非列表、真实子节点或无效位置也整体禁用，不部分执行。
  范围内部分项目转段落后，该混合选区的缩进按钮禁用，可重新选择剩余列表继续操作。
- T 类型菜单通过同文件 `changeCollabListType` 对点击时的当前选区执行有序/无序/Todo 互换。
  各项保留 depth、完整 Delta、对齐和光标/选区方向、偏移、类型；支持正反向范围及块选区。
  同类型项目不替换，也不重置编号或勾选；全部同类型不产生历史或增量。进入 Todo 默认未勾选，
  离开 Todo 清理勾选；进入有序列表按上文同层计数器续号，无前项时从 1 开始。只读、销毁、
  无效位置、真实嵌套和列表/非列表混选不部分执行。整个选区一个事务/一个撤销步骤。
  菜单执行期间拒绝重复提交，异步完成只刷新仍挂载且持有相同编辑器的菜单。
  `＋` 的非空块后插入新块与空块原位转换语义独立，继续沿用现有行为。
- 类型切换只清理源类型专有的 order/start/continuePrevious/ms/heading 与 checked/created，
  未知 props/meta 和共享正文扩展继续克隆。正常切换移除内存旧编号投影；撤销恢复有序类型时
  保留历史编号投影，由 Rust 在新身份替换中初始化 start/continuePrevious、heading 和样式。
  编号原始 JSON 先在写事务前按白名单验证，保留 missing/null/0/自定义起点区别；order 不从历史
  写回，统一按现结构重算。默认历史样式写入 null，阻止插入阶段误继承上文 ms；正常新转入
  有序项仍走桌面插入时的样式继承规则。既有同类型快照继续只读，显式编号命令入口保持独立。
  撤销/重做沿用身份链，恢复原勾选与编号；正向再次切回原类型不复活旧完成状态或起点。
- 键盘退级与工具栏共用层级事务。深度变化只原位更新所需属性，逆操作不恢复旧正文、勾选、
  对齐或只读编号投影；结构转换仅替换改变类型的项目，使用既有身份链。每组删除/插入净块数为 0，
  其他项目路径保持，原生确认继续原位回写，以维持焦点、输入连接和批量选择。
- `collab_block_delete.dart` 的 `collabBlockBackspaceCommand` 与 `CollabBlockBackspaceInterceptor`
  共用优先级：列表退级 → 标题保护 → 前置资源删除 → 标准退格。列表之前的段落、标题、
  图片/视频不会在退级时被合并或删除。IME 只将移除 AppFlowy 行首占位符后位置 0 的折叠删除
  作为退级，前向删字与候选词删除不接管。硬件同步命令由独立异步异常边界等待事务并上报。
  移动工具栏拥有拦截器，在首帧服务挂载后注册；编辑器更换时注销旧服务再注册，退出时注销，
  不关闭借用的键盘服务或外部 EditorState。属性确认原位回写，保持焦点与输入连接。
- 有序项退级若存在正数 start，深度与既有「继续编号」命令在一个事务提交，接续目标父层
  计数器；Undo 精确恢复原始起点，连续退级可逐步撤销。逆操作只保存涉及的属性，避免
  覆盖正文和原生派生编号。无序/待办项仅修改层级，不提交有序编号命令；三种列表退到最外层后
  转段落均使用既有身份替换链。无需扩展 Rust 桥接协议或 `cses.common` WebSocket。
- Todo 有正文时回车新增未勾选的同级待办项，不复制原项完成状态；原项勾选保持不变。
  空项逐级退级只改 depth，保留当前勾选。最外层转段落后不再展示待办状态，Undo/Redo
  通过现有类型转换及属性历史恢复待办类型、层级与勾选；原生 checked 沿用既有同步协议。
- Demo 引用本地 `packages/appflowy_editor`：UndoManager 重做通过 `ApplyOptions.isRedo`
  标记历史回放，每个重做命令独立进入撤销栈且保留其余重做记录；普通新编辑清空重做栈，
  即使此前已撤销所有命令也同样处理。远端投影不记录历史；定时封存不能合并重做边界。
  列表回归覆盖已有其他历史时的连续重做、跨封存时间后的逐步撤销，以及撤销后新输入。
- `collab_ordered.dart` 是不可变投影，`collab_ordered_marker.dart` 通过现有
  `NumberedListBlockComponentBuilder.iconBuilder` 扩展点展示 Rust 编号及桌面 ms 预设。
  AppFlowy 自带编号仅扫描相邻节点，格式化方法为私有，无法表达跨段落续号和正式标题计数；
  因此只替换标记绘制，输入、选区、IME 和列表布局继续由原组件负责。
- 正式列表在可编辑状态下点击序号可选择「继续编号」「重新编号」。继续编号写入
  `start: 0, continuePrevious: true`，沿用上方同层级/同标题计数器，没有前项时从 1 开始；
  重新编号写入 `start: 1, continuePrevious: false`，从当前项开始递增，保留后方显式起点。
  自定义起点（如 5）也可改成 1。普通段落不打断续号；其他缩进/标题边界遵循同一算法。
- 编号设置通过独立 AppFlowy 属性事务进入 Undo/Redo，与只读派生 order/ms 投影分开。
  桥接的 `numbering` 只保存原始 start/continuePrevious JSON，精确保留缺失、null、0 和
  自定义起点；仅该属性的本地 UpdateOperation 生成一次性 `numberingEdit`，普通文字、
  格式、排序、远端投影不会携带写入命令。Rust 在任何写入前限制命令键及目标类型，
  在同一 Yrs 事务中写设置及后续 order，再走既有 SQLite 和 CSES WS V1 增量链路。
- 菜单按稳定块 ID 提交，Undo/Redo 在同步 before 阶段按稳定 ID 重定位编号操作；
  远端重排不会把编号写到历史路径上的另一项。目标被删除/转为其他类型时取消，
  预览、只读和已销毁编辑器不执行。离线私有草稿没有正式编号投影，不展示该菜单。
  编号操作保留块身份、正文、行内格式、ms 和其他原生属性，`cses.common` 无需扩展。
- 可编辑状态下，完整 `collabSync` 应用后检测并补齐缺失/过期 order；该修复纳入向量补传，
  不另发重复正文消息。普通远端增量只读取/投影，避免对尚未完整到达的列表提前写回。
  用户预览、锁定、未知结构或其他只读条件下不自动修复；后续可编辑握手时重试。
- 跨 flavour 转换（如 paragraph→ordered）创建新 ID，并携带仅在本地桥接使用的 replacesId。
  Rust 前置校验来源唯一且不再保留于根列表，深拷贝原生共享类型及扩展属性后替换根 children，
  使桌面观察到旧组件删除和新组件插入。正文/排序及 paragraph 的标题级别变化保持原身份。
  原位 flavour 转换会被拒绝，不允许只改类型字段而留下旧桌面组件。
- AppFlowy 撤销/重做通过当前文档内的身份链替换最新原生块，保留扩展数据；远端投影不进入
  本地历史。切换文档或清缓存时清除身份链及 Undo/Redo，防止上一文档的操作写入新文档。
- 原生编号确认及远端属性投影在根块 ID、类型、顺序一致时原位更新，包括无 Delta 的图片、
  视频、链接和封面。不能因文档包含媒体就删除再插入全文，否则远端路径变换会让 Enter
  后的光标越出文档并断开输入。实际结构变化仍走结构事务；属性回写不进入撤销或广播。
  图片按当前节点读取 URL/布局/题注；视频独立保存已加载源，以控制器身份守卫迟到初始化，
  换源和页面退出释放所属播放器。回归覆盖列表行首/行中/行尾 Enter、空项退出、连续输入、
  Undo/Redo、Android 输入连接和中文续输，以及媒体原位属性更新与视频加载中退出。
- 旧版本已产生的漏号列表在可编辑握手后补齐编号；桌面若仍挂载旧段落组件，需要重新打开文档一次。
  桥接模型变动后必须完整重编译并安装原生库，不能仅 Hot Restart。
- 脱敏测试覆盖三个连续项目、中间删除、段落续号、缩进、标题边界、显式起始值、预设继承、
  替换来源校验、撤销重做、未知属性和 SQLite 恢复。`verify-ordered.cjs` 使用已安装桌面包的
  实际计数及标记函数回读 FRB 输出，并检查旧身份删除与父 children 结构事件。
  真机验收应补充列表前后插入/重排、快速撤销重做、两端同时编辑和断线后重连。
  编号菜单测试还覆盖中途重启、跨段落接续、自定义起点恢复、原始 null/缺失、旧投影不覆盖
  设置、重复命令、非法命令原子拒绝、远端重排后的 Undo/Redo、目标删除及只读拦截。
  `ordered_numbering_native_test.dart` 使用真实 FRB 和临时 SQLite 验证完整命令/历史链路。
  有序/无序/Todo 列表共用多级 Enter 回归，覆盖 depth 0～6、行首/中/尾富文本拆分与对齐、
  连续退级与输入后新增同级项、逐步撤销/重做、真实 Rust 增量及 SQLite 恢复；
  有序项额外覆盖自定义起点撤销及原生编号；Todo 覆盖勾选/未勾选项拆分、退级与历史恢复，
  原生桥接和 SQLite 恢复检查 checked 不丢失。Android IME 回归三种列表逐级退出到普通段落，
  检查光标和输入连接。真机还应验证中文候选词提交、快速连续回车和两端同时修改层级。
  Backspace 回归覆盖三种列表 depth 0～6、有正文/空项、相邻标题/媒体、候选词/前向删除
  拦截边界、真正嵌套节点、Todo 勾选/未勾选及完整 Undo/Redo。软键盘与硬件键盘均验证
  逐级退出后中文续输；真实 FRB 检查原生编号、自定义起点恢复、V1 增量和 SQLite 持久化。
  真机还应补充快速连续退格、输入法切换、双端同时退级，以及预览切换后再次进入编辑。
  工具栏回归额外覆盖项内光标、空项、0～6 级上下界、混合三种列表的正反向批量操作、
  原生起点/编号恢复和一次点击一次 V1 更新；真实输入连接验证中文续输及批量转换后的选区/焦点。
  类型互换回归覆盖六种方向、重复点击、0～6 级、有正文/空项、富文本、正反向混合选区、
  Undo/Redo、原生格式/编号/勾选及 SQLite 恢复；两个正式 Yrs 副本检查 V1 增量收敛，
  编号历史同时覆盖 missing/null/0/自定义起点与非法设置拒绝。真机建议覆盖快速切换、
  候选词提交后立即切换、与桌面同时编辑，以及断线重连后的状态一致性。
  深度历史还检查不会覆盖远端新正文、勾选和格式。真机应补充快速连点、跨图片选区禁用、
  多端同时调整层级和中途重连。
  设置 `CSES_BLOCKCRAFT_NUMBERING_INTEROP_OUTPUT` 可导出脱敏命令结果，并作为
  `verify-ordered.cjs` 的可选第 4 个参数回读；脚本复用桌面实际计数/格式化代码检查编号结果。

### 正式图片块

- 当前安装包的 `ImageBlockSchema` 是 `nodeType: block`，子块为 `caption`（editable/Y.Text）；
  兼容已有 void 空图片，但新图片使用正式 block 类型。题注在 bridge 的 image.captions 中传递，
  不加入根级块顺序，替换图片 URL 或修改正文不会重建题注。
- `wr` 为正文宽度百分比，`ar` 为宽高比；比例宽度优先于旧 `width/height` 像素尺寸。
  缺省显示 100% 和 4:3，旧尺寸超过手机宽度时等比例缩小。屏幕布局计算不写入 Yrs；
  原 rotation 参与显示，普通编辑保持旋转、旧尺寸和未知 props/meta 不变。
- `collab_image.dart` 提供不可变布局投影；`collab_image_content.dart` 复用既有资源块选区外壳，
  渲染 HTTP(S)、data URI、空图片和其他端 blob 上传占位。data URI 在后台解码，迟到结果不回写已销毁视图。
  URL/尺寸/题注变化均纳入投影相等判断，不能缓存旧 URL 的 Image Widget。
- 图片下方“编辑图片”可修改链接、宽度百分比、宽高比、对齐与题注，并可删除图片。
  `collab_image_editor.dart` 通过单次 AppFlowy 事务提交，Rust 只更新改变的共享字段。
  表单保存基准投影；远端移动后按 blockId 找当前节点，未改字段采用最新值，同字段冲突拒绝覆盖。
  弹窗 State 拥有输入控制器，关闭过渡结束后释放；只读时不显示入口，命令与 Rust 同时校验。
- 题注提供纯文本显示/输入；原 Y.Text 的富文本和未知行内属性保留，文字修改使用 UTF-16 差量，
  不清空重放格式。图片删除时一并移除其已支持的题注；含未知子块的图片整体显示不可编辑占位，保留原始子树；锁定题注和内嵌对象继续触发整篇只读。
- 图片添加使用底部“链接 / 本地上传”面板，系统文件选择支持 PNG/JPG/GIF/WebP（60MB），通过 CSES OSS 上传并登记文件后插入稳定 URL；相册专用入口和拍照尚未接入。
- 回归样本 `blockcraft-image.update` 使用 Yjs 13 编码当前图片结构，覆盖未知属性和富文本题注；
  `collab_image_test.dart` 覆盖布局、表单、只读与竞态，原生集成测试覆盖 FRB/SQLite。
  真机应补充桌面替换 URL、只改尺寸、并发题注、断网恢复及上传中 blob→正式 URL 的验收。

## 编辑页面移植

宿主只依赖 `cses_document_collab` 的公开入口，传入正式 docId、企业/用户/服务端缓存身份、数据库路径、Gateway 与授权。编辑页为 `CollaborativeEditorPage(collab: controller)`。Binding/页面宿主负责等待 initialize/close，包负责 native 初始化和本地化。

后续迁入 SaaS 的具体配置与示例见 [接入文档](docs/collab-package-integration.md)。包目录可以整目录移动，当前 AppFlowy fork 仍需由最终 App 解析。

## 非生产能力

当前 Demo 只接入 CSES WS。本机回环测试验证 Common 的连接、路由与协同协议，
不证明真实环境已发布协议或已完成登录鉴权与持久化联调；需要使用有效测试账号和文档单独验收。
当前服务端协同 WS 的文档权限校验边界以对接文档为准，不能从 ACCESS_DENIED 错误码推断已具备隔离。

部分 CSES 环境下发 `ws://` 地址，Demo 为兼容这些环境保留 Android cleartext 和 iOS ATS 配置。
接入业务环境时必须使用 `wss://`，并移除
`android:usesCleartextTraffic="true"` 与 `NSAllowsArbitraryLoads`。

## 建议补充的真实环境验收

- 两台手机加入同一正式文档，应保留已有根和正文，不插入 Demo 头部；只有空 root 时，
  首次编辑产生正式 paragraph，完全缺少 root 时只读等待业务初始化。
- cookie 过期、deviceId 不匹配、正式 docId 不存在；断网编辑后重连、前后台切换及重复连接。
- 切换账号/企业/文档时缓存不串用；同步中退出不产生迟到投影；重复进入退出无残留订阅。
- Common 同步发送异常导致队列重放时，旧 join/leave/Awareness 对当前会话的影响。
- 超过 1 MiB 的补传不能切原始字节；非法共享类型或混合模型缓存应在修改权威 Doc 前拒绝。
- 未知块和未适配容器显示不可编辑占位，其他已识别块继续编辑；行内对象、锁和修订保持整篇只读。
- 双端重启恢复、中文/Emoji/格式/块顺序收敛，以及真正的服务端持久化结果。


### 桌面高亮块（callout）

- 使用桌面正式 `flavour=callout` / `nodeType=block`；容器的 `children` 仍为 Y.Array 子块 ID，正文仍在各子块自己的 Y.Text 中，不将多段正文展平到根节点。
- 移动端投影用 `parentId` 表达高亮块父子关系。表情、背景色、边框色、文字颜色分别映射 `props.prefix` / `backColor` / `borderColor` / `color`；普通正文编辑保留容器的未知属性、元数据及原生行内格式。
- 添加面板中的“高亮块”创建带 `📢` 和空段落的容器。点击前方表情打开表情弹窗，支持常用表情、自定义输入及移除表情，选择或应用后自动关闭；点击右侧设置按钮打开独立颜色弹窗，支持背景色和边框色选择/清除，修改后保持打开，便于连续调整。文字颜色通过键盘上方 Aa 菜单设置；桌面已有的容器文字颜色在正文没有显式行内文字颜色时继承显示。
- 外观设置每次只修改一个字段；Undo/Redo 按稳定容器 ID 定位，远端重排后也不会撤销到其他块或恢复过时正文。子段落 Enter 留在容器内，首段行首退格保护容器边界。预览及模型只读时不提供修改入口。
- Rust 在写入前验证父节点与前序结构，拒绝无效父节点/循环；高亮块内未适配的块显示不可编辑占位，其他子块继续编辑；行内对象或锁继续触发整篇只读保护。含占位的容器不能整体删除，其他容器删除时移除已投影的后代。
- 验证：`collab_callout_block_test.dart` 覆盖渲染、颜色/表情设置、逐项撤销、远端更新与重排、插入与键盘边界；`callout_native_integration_test.dart` 验证真实 FRB 和 SQLite；Rust 使用 Yjs 13 生成的 `blockcraft-callout.update` 验证共享结构、未知属性及并发收敛。


### 视频兼容与统一占位

- 桌面视频使用 `props.url` / `sourceType`，图片仍用 `props.src`。兼容旧移动端视频的 `src`，但显式 `url` 始终优先；修改视频地址和新建视频写入正式 `url`，不清理未知字段。
- HTTP(S) 视频资源使用原生播放器；空地址、blob 上传中地址、嵌入代码或未知来源保留原始数据，显示“未适配的块（不可编辑）”卡片，不影响其他块编辑。
- 编辑器组件校验失败也使用同一占位卡片，不再显示英文 `placeholder`。支持的视频加载中或播放失败仍使用视频自身的状态提示。
- `blockcraft-video.update` 使用 Yjs 生成真实桌面视频结构；回归覆盖地址读写、旧字段兼容、不支持形式的原数据保留及 SQLite 恢复。


### 六类资源块

- 正式 `attachment` / `audio` / `bookmark` / `embed` / `juejin-embed` / `figma-embed` 使用桌面 `void` + `props.url` + 空 Y.Array。`CollabResource` 仅投影已建模属性，原始扩展 props/meta 始终保留；显式字段补丁经白名单校验后进入同一 Yrs 事务，不重放旧属性或旧 URL。
- 附件显示名称和大小，可交浏览器打开/下载；音频使用独占播放器播放、暂停及拖动进度，换源和退出释放控制器；网页卡片、网页、掘金和 Figma 统一使用 `metalink ^2.1.0` 提取原始 URL 元数据，由 Flutter 绘制原生预览卡片，不使用 WebView；支持加载状态、失败重试和外部打开。已保存的自定义标题/摘要/配图优先，提取结果仅本地展示，不自动写回协同正文。
- “添加”提供六类独立入口。资源卡片设置支持链接、名称/标题/摘要或卡片宽度（旧宽高比/高度数据保留，卡片高度随内容变化）；每个字段独立撤销，历史按稳定 blockId 定位，远端改动同字段时提示重开设置。预览隐藏修改/删除入口，保留播放和浏览。
- 空地址、上传中的 blob、不支持的来源或品牌链接保持统一只读占位，其他块继续编辑。应用内下载管理、桌面预览服务及原始 HTML 嵌入暂未接入；私有站点或元数据缺失时保留原始链接；详细范围见 `docs/block-adaptation.md`。
- `blockcraft-resources.update` 是 Yjs 生成的六类真实共享结构。测试覆盖原生字段保留、显式补丁与并发合并、SQLite/FRB 恢复、属性撤销、音频换源释放以及原生卡片元数据提取/换链/失败重试与过期响应隔离。
### 移动端资源添加底部面板

- 图片、视频、音频、附件和封面统一使用底部面板，分“链接”和“本地上传”两个 Tab；网页卡片、网页嵌入、Figma 和掘金等链接型内容使用相同的底部链接面板。
- 本地上传通过系统文件选择器单选；图片上限 60MB、音频 50MB、视频/附件 100MB。展示选中文件和上传进度，失败可重试，关闭面板取消请求；链接与文件 Tab 切换保留输入。
- 使用已有 CSES 登录态获取 OSS 凭证，上传后登记文件；用户原文件不重命名、不删除。仅上传和登记成功后才创建协同块，使用稳定 HTTP(S) URL，附件和音频保留名称/大小，附件另保留 MIME 类型。
- 打开面板前独立保存光标/选区与稳定块 ID，面板期间正文失焦并暂停输入连接和快捷键；资源插入仍按原块位置定位，高亮容器内保持父子关系。确认后将光标移至资源后的正文，取消后恢复原选区、方向及待输入样式，均等关闭动画结束再恢复键盘；两层面板全部关闭前不恢复正文焦点。原块被远端删除、文档只读或账号切换时不插入。
- `editor_media_source_sheet_test.dart` 覆盖来源切换、取消/失败重试/只读竞态、大小限制、元数据及窄屏键盘布局；图片、视频、音频、附件已完成 Android 真机 OSS 上传、文件登记及服务端文档回读验证，音频还验证了播放/暂停/拖动与恢复后完整播放；封面的真实上传仍需单独验证，详见 [OSS 联调记录](docs/oss-upload-integration.md)。
- `editor_modal_focus_test.dart` 使用真实 AppFlowy 键盘服务验证面板与正文焦点隔离、取消恢复、协同重排/删除及上传期间的插入锚点。

- 2026-10-14 联调修复：资源插入明确分配新协同块 ID，避免替换空段落被识别为旧块转换，导致附件名称/类型/大小未初始化；回归覆盖新建身份及元数据。
