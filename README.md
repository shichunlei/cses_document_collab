# CSES Mobile Collab Demo

一个独立运行的 Flutter + Rust/Yrs 离线协同实验。协同核心位于 `packages/cses_document_collab`；根 App 装配登录、Common 主连接、上传与缓存路径。

桌面块的完整移动端适配进度见 [块适配表](docs/block-adaptation.md)。每完成一个块的适配，都须同步更新该表的状态、支持范围及验证记录。

## 已实现

- AppFlowy Editor 6.2 块编辑界面和连接状态
- 独立全屏 `CollaborativeEditorPage`，与 Demo 的连接配置页面解耦
- `CollaborativeEditorPage` 支持编辑/预览切换；预览时收起键盘和工具栏并禁止文档修改
- 正式文档业务头部：显示桌面封面、图标（emoji/图片，含 SVG）、标题，封面铺满屏宽，居中叠加更换/移除/调整按钮，图标跨在封面下沿；支持封面“公共图库 / 上传 / 链接”三 Tab（复用桌面20张图库）、移除及位置调整、图标“表情符号 / 上传 / 链接”三 Tab 选择/替换/移除、标题修改；保存复用 Common HTTP 业务接口
- 基于键盘 Insets 的稳定移动快捷栏，T/Aa/块布局二级菜单展开时不收起键盘
- 参考移动文档产品的“添加”底部面板，标题菜单支持 H1～H6、两种列表、Todo、引用、高亮块、链接、图片和视频
- T 菜单从 H1～H3 开始按需逐级展开到 H6，并包含列表、Todo、代码块和引用；三种列表互换保留层级、正文格式及光标/选区
- Aa 菜单包含加粗、斜体、下划线、删除线、行内代码、文字颜色、上标和下标
- Aa 行内格式在当前段落内持续生效；再次点击当前格式或切换段落时取消
- 块布局菜单支持整块背景色、引用块左侧线条颜色（与桌面 `props.backColor` / `props.borderColor` 双向同步，支持清除及撤销），左/中/右/两端/分散对齐和三种列表的 0～6 级缩进；最外层减少缩进转普通段落，保留光标/选区
- 行内加粗、斜体、下划线、删除线、行内代码、文字颜色、上标和下标使用 Y.Text 原生 attributes 协同
- Todo 新建、段落/Todo 转换以及勾选状态实时协同
- 代码块使用白底细边框和浅色标题栏，支持修改名称、搜索选择语言、折叠/展开、复制完整源码和语法高亮；`props.blockName` / `props.lang` / `props.collapse` 与桌面同步并支持逐字段撤销，预览折叠只影响本机，着色不写入 Y.Text
- 高亮块兼容桌面 `callout` 容器；点击前方表情打开表情弹窗，可更换/移除、自定义表情；点击右侧设置打开独立颜色弹窗，可修改背景色和边框色。文字颜色使用键盘上方 Aa 菜单设置。支持逐项撤销和离线恢复，块内多段正文保持独立编辑和协同
- AppBar 撤销/重做；远端 transaction 不进入本机 UndoManager
- AppBar 导入 Markdown（UTF-8、`.md` / `.markdown`、最大 5 MiB），追加到文末并整体撤销；表格转文本行，独立网络图片转图片块，其他图片保留地址，不上传本地资源
- AppFlowy transaction 与 Rust/Yrs 块级 Schema 适配层：离线草稿沿用 Demo 模型，CSES 文档使用正式 BlockCraft 模型
- `paragraph`、`heading_1`～`heading_9`、`bulleted_list`、
  `numbered_list`、`todo_list`、`quote`、`code`、`callout`、`link`、`image`、`video`
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

正式文档头部独立于上述正文块。宿主通过 `CollabHostServices.documentMetadata`
注入 `DocumentMetadataService`，Demo 的 `CsesDocumentMetadataService` 使用
`cses_common/network/http/client/http_manager.dart` 读取 `/doc/document/view` 和
`/doc/permission/read`，通过 `/doc/document/modify` 修改名称、icon 或 banner，
移除图标/封面使用 `/doc/document/icon/remove`、`/doc/document/banner/remove`。
仅业务接口确认后更新头部；失败保留原值，可重试。正文撤销不撤销头部业务修改。
图标/封面操作按桌面 owner 角色控制，改名检查实际 owner 身份，仅 `abilities.rename == false` 时禁止（兼容权限字段缺失）；
预览和宿主只读状态禁止修改。前台恢复、重连及重新打开时获取桌面最新头部。

离线草稿只包含正文；不再创建或支持 `document_cover`、`document_title`。
旧私有草稿加载时按原始类型删除这两个头部块并持久化，保留其余正文、格式和顺序；
该迁移不会把旧 Demo 标题/封面写入正式文档的业务字段，也不会修改正式 blocks。

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
未适配的正文行内对象仅保护所在段落；锁定块、修订记录、未知顶层根及图片题注等既有约束继续限制整篇编辑。普通正文已支持行内公式和用户、会议、任务、文档四类提及，范围见下文及适配表。
结构重复/循环、缺失子块等情况同样限制编辑。正式正文缺少根时等待初始化，
不自动创建根、封面或标题；业务界面空白不代表 Yjs 文档无结构。
只读约束同时在页面输入和 Rust 写事务前检查。手机专属独立链接块没有隐式正式对应，相关操作会被拒绝并恢复 UI。

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
- Demo 按 SaaS 账号密码流程先初始化 Common 的 PRE 配置、偏好和设备信息，再通过 `HttpManager` 的共享 Dio 请求 `/User/login`；公共 header 和异常映射均由 Common 提供。首页仅启动主 WebSocket 连接，不自动选择文档，不保存密码或登录账户快照。
- 登录成功后由 `CsesAccountLogin` 将完整响应交给 `User().resolveContext(value)`，统一解析身份、企业、权限、媒体站点、域名和 WebSocket 地址，校验通过后才进入首页。企业选择复用 Common 的组织排序和上次企业偏好；Demo 不再保留响应副本、手动推导企业或覆盖连接地址。页面已销毁的迟到响应不注入上下文；解析/校验失败清理本次用户态，留在登录页重试。
- 登录成功直接通知页面切换，账号与展示名读取 Common 的 `User`，不传递独立会话对象。`DemoDocumentHost` 选择旧 SQLite 路径，在创建控制器时直接使用 `ctx.websocketHost`、`User().companyId`、`User().userId` 和展示名构造 `CollabDocumentConfig`，再注入 Gateway、ID、日志和媒体上传；不再次解析登录或请求 `/User/auth`。包直接打开正式模型，不先打开草稿；离线预览和测试显式设置 `localDraft: true`。
- 文档 ID、服务端、企业、用户和数据库路径只在 `CollabDocumentConfig` 中形成不可变快照；缓存键由协同包统一计算，宿主不保存 Cookie 副本或重复维护缓存算法。切换身份须关闭旧控制器后重新创建。
- WebSocket 地址和默认协议以 Common 解析结果为准。若与历史 Demo 的默认地址不同，按现有地址/企业/用户/文档缓存键进入对应分区，旧缓存仍保留。
- `DemoDocumentHost.initialize()` 完成表示账号服务、创建记录恢复及主连接启动已调度，不打开文档；从“文档列表”点击条目后才核验访问权限、恢复缓存并进入编辑页，返回后保留列表位置。新建也在列表页完成并从该页进入编辑器；文档控制器的 `initialize()` 完成表示本地恢复和回调注册完成；协同 ready/online 只表示客户端差量交换，不是服务端落库回执。
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
不再手动填写 userId、cookieId、companyId 或 WS 地址。登录成功后首页只启动主连接；
通过“文档列表”选择文档，或在列表右上角新建后进入编辑页，返回时回到原列表。
首页可重新连接或退出登录，选定文档后可清理其本机缓存。
会话只驻留内存，重启后重新登录；SQLite 正文缓存仍按地址/企业/用户/文档隔离并保留。

首页另有“离线本地编辑 → 开始离线编辑”入口，文档加载中或连接失败时仍可打开。
文字编辑能力由包内实例配置选择；模板预览隐藏编辑装饰，本地不提供块锁和图片导出。
正文仅保留在本次会话内，不写入协同文档、服务端或相册；返回首页后可从文档列表进入协同编辑。

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
首次使用 Xcode 前先执行 `scripts/build_rust_ios.sh debug`，再执行
`flutter build ios --debug --config-only` 并打开 `ios/Runner.xcworkspace`。
之后 IDE 的完整 iOS 构建会自动执行 Runner 的 `Build Rust iOS Library` 阶段：
Debug 使用 Rust dev，Profile/Release 使用 release，真机和模拟器均受支持。
该阶段也覆盖 VS Code、Android Studio 的 Flutter 启动和直接 `flutter run/build`；
Cargo 增量编译后刷新 SwiftPM 已处理的 framework，Rust 构建失败会中止应用构建。
IDE 启动的 Xcode 无需继承交互终端 PATH；构建脚本会补充标准 Rustup/Homebrew 路径。
全新检出的首次 SwiftPM 解析仍需要上述初始化入口，因为解析发生在 Runner 构建阶段之前。
iPhone 首次运行需要在 Xcode 中配置开发者签名。

`cses_document_collab` 保留 `.podspec` 和 Cargokit 构建脚本，供其他使用 CocoaPods 的宿主接入；
本宿主不提供 CocoaPods 回退配置。
当前 Android 构建输出位于 `build/app/outputs/flutter-apk/app-debug.apk`。
Rust 或 FRB 桥接声明变化后必须停止运行并完整重新构建安装；热重载/热重启不能替换已加载的原生库。

若打开文档出现 `Content hash on Dart side ... is different from Rust side ...`，
说明应用加载的 Rust 库与当前 Dart 桥接代码不匹配。先停止当前调试会话；iOS 使用
`scripts/ios.sh run -d <ios-device-id>` 重建原生库并重新安装启动，Android 完整执行
`flutter run -d <android-device-id>`。只执行热重启、依赖解析或单独生成 FRB 代码不能更新
手机进程中的原生库。包内原生测试另需执行
`cargo build --locked --manifest-path packages/cses_document_collab/rust/Cargo.toml`。
从仓库根目录执行使用默认加载器的原生测试时，通过
`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$PWD/packages/cses_document_collab/rust/target/debug" flutter test <测试路径>`
指向该动态库；包内显式指定动态库路径的测试无需此环境变量。
保留 FRB 的内容哈希检查，不通过跳过检查或手工修改生成文件规避版本不一致。

建议按以下顺序验收当前块级阶段：

1. 手机 A 输入中文、Emoji 和多段 paragraph，手机 B 应实时出现；
2. 独立离线草稿检查只含正文；正式文档核对桌面封面、表情、名称，修改/移除后重开桌面确认，并验证只读、失败重试与前台刷新；
3. 光标进入正文后，确认键盘上方出现 `＋ / T / Aa / 块布局 / 图片 / @`
   快捷栏；
4. 选中文字后点击 `Aa`，验证粗体、斜体、下划线、删除线、行内代码和文字颜色会同步；
5. 点击 `T`，验证 H1～H6 的逐级展开，并确认不显示 H7～H9、有序/无序列表、Todo、代码块和引用块；点击 `Aa` 验证上标和下标；Todo 勾选后手机 B 应同步状态；
6. 点击块布局，验证对齐方式与列表缩进在手机 B 同步；
7. 点击 `＋`，验证 H1～H6、两种列表、Todo、引用、链接、图片和视频块同步；
8. 插入链接/图片/视频时填写完整的 HTTP(S) URL；资源块后应自动定位到空正文并弹回键盘；
9. 光标停在资源块后方段落的第 0 位时按退格，资源块应删除、当前段落与键盘应保留，并同步到另一台手机；
10. 空块会原位转换；当前块已有正文时，会在其后插入所选的新块；
11. 点击顶部撤销/重做，操作结果应继续同步到另一台手机；
12. 两台手机在不同块同时输入，最终块顺序、类型、文本和样式应一致；
13. 两台手机在同一块同时输入，Yrs 应合并双方文本；
14. 手机 A 断网后继续新增块、输入、设置格式或勾选 Todo，恢复后应收敛；
15. 杀掉并重启任一客户端，应先从 SQLite 恢复，再与服务器补齐。
16. 未知块和未适配容器显示不可编辑占位，其他已识别块仍可编辑；未适配的行内对象、锁或修订保持整篇只读，原始内容和父子关系不变；
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

正式头部已接入文档业务名称、图标和封面接口及对应权限；正文 `/doc/document/edit` 的 dirty-block 快照、评论和完整正文业务权限仍未接入。
Awareness 展示用户和在线数，尚未对齐桌面光标/选区契约；不能用 ready 或 SyncStatus 声称业务落库成功。
普通及合并表格已支持新建、行列增删、矩形范围合并/拆分、列宽设置、横向滚动和正文编辑/撤销/协同；不完整或超限表格与其他未适配复杂布局仍保留为占位，具体范围见[适配表](docs/block-adaptation.md)。其他已识别块仍可编辑；未适配的行内对象、锁与修订继续整篇只读，后续按对应语义适配。

当前同步顶层块的类型、顺序、文本/URL、Todo 勾选、对齐和视觉缩进，以及 bold、italic、underline、
strikethrough、inline-code、textColor、backgroundColor、superscript、subscript 行内属性。当前缩进保持扁平块
Schema，仅表现为列表/Todo 的视觉层级，不会生成 AppFlowy 子节点。链接、图片和视频 URL 使用各块现有
bridge 的 text 字段传递；正式图片写入 props.src、视频写入 props.url；图片使用 block 类型，children 为题注 ID 数组，
视频沿用 void 与空 Y.Array；离线 Demo 的
链接/图片/视频使用私有 Y.Text 载荷。正式链接形式采用带 `a:link` 的段落，通过href片段投影同步，不新增独立link flavour。
语义嵌套列表、Awareness 光标与选区暂时不会同步；表格已支持新建及行列/合并/列宽操作，拖拽式多格选区和表格复制粘贴仍待接入；
其他未适配入口仍显示“后续阶段”提示，不会插入 Rust Schema 无法保存的节点。

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
  共用优先级：列表退级 → 容器边界保护 → 前置资源删除 → 标准退格。列表之前的段落、标题、
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
  视频和链接。不能因文档包含媒体就删除再插入全文，否则远端路径变换会让 Enter
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
- 未知块和未适配容器显示不可编辑占位，其他已识别块继续编辑；未适配的行内对象、锁和修订保持整篇只读。
- 双端重启恢复、中文/Emoji/格式/块顺序收敛，以及真正的服务端持久化结果。


### 桌面高亮块（callout）

- 使用桌面正式 `flavour=callout` / `nodeType=block`；容器的 `children` 仍为 Y.Array 子块 ID，正文仍在各子块自己的 Y.Text 中，不将多段正文展平到根节点。
- 移动端投影用 `parentId` 表达高亮块父子关系。表情、背景色、边框色、文字颜色分别映射 `props.prefix` / `backColor` / `borderColor` / `color`；普通正文编辑保留容器的未知属性、元数据及原生行内格式。
- 添加面板中的“高亮块”创建带 `📢` 和空段落的容器。点击前方表情打开表情弹窗，支持常用表情、自定义输入及移除表情，选择或应用后自动关闭；点击右侧设置按钮打开独立颜色弹窗，支持背景色和边框色选择/清除，修改后保持打开，便于连续调整。文字颜色通过键盘上方 Aa 菜单设置；桌面已有的容器文字颜色在正文没有显式行内文字颜色时继承显示。
- 外观设置每次只修改一个字段；Undo/Redo 按稳定容器 ID 定位，远端重排后也不会撤销到其他块或恢复过时正文。子段落 Enter 留在容器内，首段行首退格保护容器边界。预览及模型只读时不提供修改入口。
- Rust 在写入前验证父节点与前序结构，拒绝无效父节点/循环；高亮块内未适配的块显示不可编辑占位，其他子块继续编辑；未适配的行内对象或锁继续触发整篇只读保护。含占位的容器不能整体删除，其他容器删除时移除已投影的后代。
- 验证：`collab_callout_block_test.dart` 覆盖渲染、颜色/表情设置、逐项撤销、远端更新与重排、插入与键盘边界；`callout_native_integration_test.dart` 验证真实 FRB 和 SQLite；Rust 使用 Yjs 13 生成的 `blockcraft-callout.update` 验证共享结构、未知属性及并发收敛。


### 视频兼容与统一占位

- 桌面视频使用 `props.url` / `sourceType`，图片仍用 `props.src`。兼容旧移动端视频的 `src`，但显式 `url` 始终优先；修改视频地址和新建视频写入正式 `url`，不清理未知字段。
- HTTP(S) 视频资源使用原生播放器；空地址、blob 上传中地址、嵌入代码或未知来源保留原始数据，显示“未适配的块（不可编辑）”卡片，不影响其他块编辑。
- 编辑器组件校验失败也使用同一占位卡片，不再显示英文 `placeholder`。支持的视频加载中或播放失败仍使用视频自身的状态提示。
- `blockcraft-video.update` 使用 Yjs 生成真实桌面视频结构；回归覆盖地址读写、旧字段兼容、不支持形式的原数据保留及 SQLite 恢复。


### 六类资源块

- 正式 `attachment` / `audio` / `bookmark` / `embed` / `juejin-embed` / `figma-embed` 使用桌面 `void` + `props.url` + 空 Y.Array。`CollabResource` 仅投影已建模属性，原始扩展 props/meta 始终保留；显式字段补丁经白名单校验后进入同一 Yrs 事务，不重放旧属性或旧 URL。
- 附件显示名称和大小，可交浏览器打开/下载；音频使用独占播放器播放、暂停及拖动进度，换源和退出释放控制器；网页、掘金和 Figma 资源支持“切换视图”：嵌入使用 WebView，卡片使用 `metalink ^2.1.0` 原生预览，链接使用带 `a:link` 的正式段落。三种形式六向互转，每次为独立可撤销事务；整段链接点击可切回卡片或嵌入，混排正文不作整块转换。支持加载状态、失败重试和外部打开。已保存的自定义标题/摘要/配图优先，提取结果仅本地展示，不自动写回协同正文。
- “添加”提供六类独立入口。资源卡片设置支持链接、名称/标题/摘要或嵌入宽度/宽高比；卡片高度随内容变化；每个字段独立撤销，历史按稳定 blockId 定位，远端改动同字段时提示重开设置。预览隐藏修改/删除入口，保留播放和浏览。
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

### 桌面分割线（divider）

- 对齐 `@ccc/blockcraft` 0.11.14 的 `flavour=divider` / `nodeType=void`：空 Y.Array 子项，外观全部存于 props，不使用 Y.Text 或资源 URL。移动端通过既有桥接属性载体传递白名单属性与显式补丁，桥接签名保持稳定。
- 支持 10 种线型、5 种贴纸胶带和 6 种花边。点击分割线打开持续编辑的底部面板，线型/花边可选择或清除线色，贴纸胶带保留自身图案且隐藏线色设置；可设置短/中/长/通栏、细/常规/粗及透明度（10%～100%）。旧 `size` 的长度/粗细回落与桌面一致；读取不会自动改写旧属性。
- 面板标题、预览和样式页切换固定，下方设置独立滚动，切换页回到顶部；页名完整单行。预览槽固定76逻辑像素，容纳最粗图案并居中显示，切换粗细不移动下方控件。清除与预设颜色使用一致的色块及选中逻辑，重复选择不新增历史，面板内权限变化即时禁用。
- “更多 → 分割线”按保存位置在根或高亮容器内插入。空正文被新分割线和后置段落替换；非空正文保留。删除按钮或后置正文行首退格删除分割线，插入/删除和单字段外观调整可独立撤销。历史操作按稳定块 ID 重定位；预览与只读禁止修改，面板退出后恢复原正文选区。
- 远端未知 props/meta 和历史文字装订属性原样保留；历史文字装订暂不提供编辑。未知样式展示实线但不覆盖原值；线色提供常用颜色，其他合法 CSS 原色仍可展示。尚未进行本次 Android/iOS 真机验收。
- `collab_divider_test.dart` 覆盖旧属性、逐字段撤销、远端重排、嵌套插入、退格、只读与面板焦点；`divider_native_integration_test.dart` 验证真实 FRB 与 SQLite 重开。Rust 的 `blockcraft-divider.update` 是 Yjs 13 生成的正式样本，覆盖全部样式与扩展字段、非法补丁原子拒绝和双端收敛。
- `tool/sync_divider_artwork.py <@ccc/blockcraft 包路径>` 从桌面主题提取 SVG 遮罩及胶带渐变，生成 `collab_divider_artwork.dart`；来源信息随生成文件保留，不手工修改。更新桌面主题时重新运行并核对视觉效果。


### 桌面公式（formula）

- 对齐桌面 `flavour=formula` / `nodeType=void` / 空 Y.Array，LaTeX 只存于 `props.latex`；不生成 Y.Text、src 或 url。复用既有属性桥接与单字段补丁，未知 props/meta 保留，缺失、null、空字符串可精确撤销。
- 原生 Flutter 渲染分式、根式、矩阵等数学表达式；长公式横向滚动，空公式显示添加提示。解析失败保留并显示原文，不在读取时改写公式。渲染依赖 `flutter_math_fork ^0.7.4`，支持的 TeX 子集与桌面 KaTeX 不完全一致。
- 点击公式打开底部 LaTeX 输入与实时预览，保存才提交，取消恢复原正文选区。远端原文变化时要求重新加载；权限撤销或目标删除立即禁用提交。
- “更多 → 公式”输入并保存后按稳定正文位置插入，支持根与高亮容器。空段落替换为独立公式和后置段落，非空段落保留；删除入口和后置段落行首退格、插入与内容修改可独立撤销/重做。最后一个容器子块删除后留下空段落。
- 编辑上限为 20000 UTF-16 单元，原文不自动添加美元符号或修剪。普通正文行内公式已支持，见下节；其他未知行内对象、代码块或图片题注中的公式仍会触发只读保护。Android 16/HONOR X70 已验证既有空公式编辑、分式/根式预览、保存后正文渲染与撤销恢复；移除行内对象后更多入口新建公式、原正文保留及后置段落光标/键盘恢复也已真机验证；删除/撤销/重做、远端冲突重新加载及真实桌面双向同步也已验证（桌面操作与观察由用户确认）：新增被桌面收到，桌面529→625回传手机，最终删除被桌面收到；原公式保留。见[联调证据](docs/verification/formula-sync-20261014/formula-sync-20261014.json)。重连恢复、服务器持久化ACK及iOS待验证。验证包含公式与相关 Flutter 81 项回归、真实 FRB/SQLite 恢复、Rust 64 项测试及 Android 调试构建。

### 桌面行内公式（latex embed）

- 正式正文的 `Y.Text` 对象 `{latex: string}` 投影为一个UTF-16位置，通过新增的 `CollabTextSegment.inlineLatex` 同步；写回保留真正的对象和未知原生格式。普通U+FFFC文字与相同的连续公式分别识别；emoji仍占两个UTF-16位置。FRB按2.13.0生成，宿主、Android与iOS原生库已重建。
- 支持段落/标题、列表、引用及高亮容器正文的原生行内显示。“添加 → 行内公式”按保存选区插入或替换同块选区，公式后恢复光标/键盘；点击公式编辑与实时预览，保存才写入，空原文或删除按钮移除一个对象，支持独立撤销/重做。长公式可横向滚动，空对象显示TeX，无法解析时显示原文。
- 按稳定块ID处理重排；目标源码被远端修改要求重新加载，所在段落文字变化要求关闭重开，过期历史拒绝覆盖远端内容。新建/修改最多20000 UTF-16单元，TeX子集受渲染器限制；代码块、图片题注、未知行内对象及旧localDraft协议尚不支持。
- 包全量668项、宿主24项、Rust66项和真实FRB/SQLite恢复通过。Android 16/HONOR X70实际验证分式新增、公式后普通输入、点击改根式、编辑/预览显示、删除与撤销/重做，测试内容已清理。修复渲染器根式intrinsic零宽度后，增加尺寸断言并真机复验。见[验收记录](docs/verification/inline-formula-20261014/inline-formula-20261014.json)。实际桌面行内双向界面联调、重连/服务器持久化ACK与iOS界面仍待验证。

## @用户（普通正文）

- 段落/标题、列表、引用和高亮正文支持真实 `Y.Text` 用户对象 `{mention: name}`，身份保存为 `mentionId` 与 `mentionType: user`，兼容历史 `d:` 前缀。一个对象占一个UTF-16位置，普通U+FFFC、emoji、重名/连续相同用户和行内公式分别保留；未知原生格式不回写为移动端私有属性。
- 输入 `@`、键盘工具栏及更多面板均可搜索并选择当前企业人员。插入替换原同块选区并追加空格；输入触发后取消保留普通@，取消面板恢复原选区。弹窗隔离正文输入，按稳定块身份跟随重排，正文/选中内容变化或权限撤销时拒绝提交。
- 头像及人员选择器均由宿主通过`CollabHostServices.mentionAvatarBuilder/pickMentionUser`注入，协同包不创建头像或搜索选择界面；未注入头像时只显示姓名，未注入选人时不打开选择界面。Demo宿主为正文提及及人员选择列表按 `https://face.jinqidongli.com/{userid}/{userid}.jpg` 加载圆形头像。路径段按ID编码，不附加认证信息；加载中/失败显示姓名首字，保持布局。头像URL仅用于本地展示，不进入Y.Text。
- 用户卡片点击仅通知宿主`onMentionTap`，由宿主处理人员详情；无回调不响应。协同包不再提供用户资料/复制/删除面板。正文选区删除和独立撤销/重做保留，预览禁止修改正文。
- 人员目录由宿主的选择器/详情页持有，不再注入协同包；可复用公开`CollabMentionDirectory`契约。Demo使用Common同源 `/Company/readAllChildren`，账号/企业/cookie在请求前后核对。组织解析和搜索在后台执行，成功缓存仅属于当前宿主实例，失败可重试，面板忽略过期/关闭请求。
- 行内适配按“部分支持”记录，正文块仍为10/8/1/22（41）。未接入拼音/首字母搜索及对象剪贴板；普通待办可保存提及，但同步任务待办的“添加参与人”业务副作用尚未接入。代码块、图片题注、未知实体提及、旧localDraft继续保护；会议/任务/文档普通正文提及见下文。显示名最多20000 UTF-16单元，用户ID最多512 UTF-8字节；Android16/HONOR X70真实搜索、插入、删除/撤销/重做及头像版复验通过；手机收到桌面新增声波/测试员1及普通文字，用户确认桌面收到手机新增和最终删除测试员。测试数据已清理；桌面操作/观察由用户完成。iOS真机、断线恢复和服务器持久化ACK尚未验证，见[验收记录](docs/verification/user-mention-20261014/user-mention-20261014.json)。

验证：编辑包682项（头像前基线679项）、宿主27项、Rust69项测试通过；头像/提及13项回归及包内静态分析再次通过。两项目静态分析、Rust格式/check、手写Dart格式及diff检查通过。FRB由2.13.0生成，宿主原生库和iOS三架构库已重建，Android调试APK与iOS模拟器构建通过。完整范围见[适配表](docs/block-adaptation.md)。


### 会议、任务、文档提及

正文已按 `mentionType` 区分用户、会议、任务、文档。后三类显示类型图标和名称，点击显示打开详情及删除操作，只有会议/任务另提供切换卡片；删除提及支持独立撤销/重做，实体本身不被修改。原始状态、编号、文档类型和任务扩展属性参与完整历史恢复；普通文字编辑不会覆盖远端更新的业务元数据。仍未接入后三类的搜索选择器；业务详情由宿主onMentionTap处理，实际支持范围及验证依据见 [块适配清单](docs/block-adaptation.md)。

本轮验证：编辑包693项、宿主27项、Rust72项及两项目静态分析通过；Android已安装到HONOR手机，三类实体提及删除/撤销恢复与桌面双向同步通过，原始属性完整保留，见[四类提及验收记录](docs/verification/entity-mention-20261015/entity-mention-20261015.json)。


### 宿主统一点击回调

`CollabHostServices(onMentionTap: (mention) async { ... })` 可接管四类提及的详情跳转；公开参数为 `CollabMentionTap`，包含 `type/id/name/attributes`，其中type为 `CollabMentionType.user/meeting/task/doc`，原始属性及其嵌套集合为独立只读快照。回调应等待详情关闭再完成；预览也可跳转，重复点击被隔离，异常统一报告。用户提及未注入时不响应；其他三类点击先打开操作面板，只有“打开详情”调用回调，未注入时详情禁用；切换卡片与删除不派发。包本身不内置业务页面。接入和路由示例见[协同包说明](packages/cses_document_collab/README.md#宿主统一提及点击回调)。本轮原始属性、异步/会话关闭及平台构建验证见[回调验收记录](docs/verification/mention-integration-20261015/mention-tap-callback-20261015.json)。

头像与人员选择器的宿主注入、生命周期契约和迁移示例见[协同包说明](packages/cses_document_collab/README.md#人员提及端口)。

用户提及已移除内置资料面板与`mentionDirectory`服务参数；点击只通知宿主。验证见[用户点击回调记录](docs/verification/mention-integration-20261015/mention-user-tap-only-20261015.json)。

### 会议状态卡片

会议详情由宿主`loadMeetingCard`提供，Demo复用Common的`/meeting/getDetail`。未开始蓝色、进行中绿色、暂停橙色、结束/取消灰色；结束或取消显示“查看会议”，其余显示“加入会议”。仅主按钮触发`onMeetingCardTap`，执行前后不额外请求详情；标题/背景/留白不派发事件，回调结束不自动弹正文键盘。删除引用放在底部作为独立次要操作，预览隐藏，窄屏大字可分行。状态、时间、主持人与人数不写入协同文档；失败可重试，迟到结果隔离，暂不订阅实时状态推送，真实入会/业务详情仍由宿主负责。

接入示例见[协同包说明](packages/cses_document_collab/README.md#会议引用卡片)，验证与预览见[状态卡片记录](docs/verification/meeting-card-20261015/meeting-card-status-20261015.json)。


会议/任务/文档提及均有“打开详情”操作，只有会议、任务提供“切换为卡片视图”。会议、任务转为桌面正式卡片块，前后文字拆分保留，支持撤销/重做；任务卡片详情复用onMentionTap，会议卡片主按钮继续使用onMeetingCardTap。文档库提及仅保留行内图标和名称，没有卡片形式，不提供手机局部卡片或视图切换。只有打开详情触发宿主回调；转换与删除均不触发。任务卡片为部分支持，正文块当前统计10/10/1/20（41）；范围和验证见[适配表](docs/block-adaptation.md)与[提及卡片操作说明](packages/cses_document_collab/README.md#提及操作与卡片视图)。


任务卡片现按桌面截图展示优先级、状态、负责人、起止时间、进度及路径/附件/子任务统计，白底细边布局支持窄屏大字。数据经宿主`loadTaskCard`注入，Demo复用Common task_v3详情；头像继续由宿主构建。右上展开图标只派发`onMentionTap`，不额外刷新数据；删除位于更多菜单，预览隐藏删除。业务详情不写协同正文，任务卡片仍为部分支持，统计10/10/1/20（41）不变。见[任务卡片说明](packages/cses_document_collab/README.md#任务卡片详情与布局)与[验证记录](docs/verification/task-card-20261015/task-card-layout-20261015.json)。 HONOR X70/Android16已完成PRE真实任务展示、详情回调、键盘与删除历史复验；审计恢复限制及截图见[真机记录](docs/verification/task-card-20261015/task-card-phone-20261015.json)。


## 宿主今日导向

独立页面位于`lib/src/daily_guidance/`，演示首页保留原入口；与原离线编辑页分别维护。页面、栏目、业务条目、组织选人、草稿与服务规则均归宿主，协同包只提供通用编辑能力。

新草稿仅有今日记录，感悟/自检点击添加后显示；关闭保留正文，可恢复、撤销和重做。键盘上方统一排列T、Aa、原生@、Todo待办及感悟/领航员/都来帮/自检四个宿主动作，单行横向滚动，收起键盘固定最右，页面下方不再重复显示入口。原生@通过编辑器单选真实企业用户，键入@与工具栏共用流程；Todo复用原生列表，不选人。都来帮/领航员复用编辑器原生@人员选择器，单选人员后另起可写业务行，使用原生人员提及格式且不提供组织选择；业务行回车后继续普通正文。旧草稿中的自定义人员/部门引用和旧业务待办继续读取。编辑与预览使用同一纸张和渲染组件，原生提及支持保存重开、可读姓名复制及本地撤销重做；预览隐藏编辑菜单。

含`@`内容复制或剪切时展开为可读的`@姓名`纯文本，粘贴后作为普通文字，不携带人员/部门身份。剪贴板写入失败，或等待期间正文、选区、编辑权限发生变化时保留源内容；普通文字不会继承邻接提及的身份属性，支持中文合成、选中替换和撤销重做。修复验证见[引用输入与剪贴板](docs/verification/offline-journal-20261022/dynamic-fixes.md)。

自动保存仍写入应用私有`local-journals/<原账号哈希>.json`，不更换账号算法或覆盖其他分区。v2兼容读取原v1三栏草稿，保留身份、日期、文字及格式；空可选栏目的内容放入关闭区，非空栏目仍显示。首次升级写盘前保留原始`.json.v1.bak`，保存失败保留正式旧稿并显示重试；损坏或未知版本不会自动重置。当前仍为每账号一份草稿。

Todo和自定义业务条目保存在本地草稿；原生列表的勾选及旧业务待办圆环均表示本地完成状态。真实业务派单、通知与状态流转尚未接入，附件/语音、完整视频封面与分享属于后续阶段。历史实现见[宿主迁移记录](docs/verification/offline-journal-20261022/host-implementation.md)。

同一日记栏目中的无序、有序和Todo列表可直接互相切换，无需先转普通段落；正文、富文本、光标与撤销重做保持。Todo快捷按钮也支持从已有列表直接转换，重复点击已勾选Todo不重置勾选。范围及验证见[列表互转修复](docs/verification/offline-journal-20261022/list-conversion-fix.md)。
