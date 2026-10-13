# CSES Mobile Collab Demo

一个与业务仓库完全隔离的 Flutter + Rust/Yrs 离线优先协同最小闭环。

## 已实现

- AppFlowy Editor 6.2 块编辑界面和连接状态
- 独立全屏 `CollaborativeEditorPage`，与 Demo 的连接配置页面解耦
- `CollaborativeEditorPage` 支持编辑/预览切换；预览时收起键盘和工具栏并禁止文档修改
- 飞书文档风格的固定头部：默认头图、可添加/替换/移除封面，以及大号可编辑文档标题
- 基于键盘 Insets 的稳定移动快捷栏，T/Aa/块布局二级菜单展开时不收起键盘
- 参考移动文档产品的“添加”底部面板，支持 H1～H9、两种列表、Todo、引用、链接、图片和视频
- T 菜单从 H1～H3 开始按需逐级展开到 H9，并包含列表、Todo、代码块和引用
- Aa 菜单包含加粗、斜体、下划线、删除线、行内代码、文字颜色、上标和下标
- Aa 行内格式在当前段落内持续生效；再次点击当前格式或切换段落时取消
- 块布局菜单支持左/中/右对齐，以及列表/Todo 的 0～6 级视觉缩进
- 行内加粗、斜体、下划线、删除线、行内代码、文字颜色、上标和下标使用 Y.Text 原生 attributes 协同
- Todo 新建、段落/Todo 转换以及勾选状态实时协同
- AppBar 撤销/重做；远端 transaction 不进入本机 UndoManager
- AppFlowy transaction 与 Rust/Yrs 块级 Schema 适配层
- `paragraph`、`heading_1`～`heading_9`、`bulleted_list`、
  `numbered_list`、`todo_list`、`quote`、`code`、`link`、`image`、`video`、
  `document_cover`、`document_title`
  的类型、文本/URL 和受支持属性同步
- 链接块可打开系统浏览器，图片复用 AppFlowy 原生渲染，视频支持网络资源内嵌播放和外部打开兜底
- 光标位于资源块后方文本块的起始位置时，软键盘或硬件键盘退格可删除链接、图片、视频块并保留当前段落
- 稳定 blockId；AppFlowy 拆分或转换节点后仍保持协同身份
- `Y.Array` 块顺序、`Y.Map` 块类型、每块独立 `Y.Text`
- 本地 AppFlowy transaction、远端 transaction 防回环
- `flutter_rust_bridge` 调用手机端 Rust
- Rust/Yrs 使用 Yjs V1 Update 和标准 y-websocket 消息
- Flutter 使用 `dart:io WebSocket`，没有引入第三方 WS 插件
- Debug/Profile 控制台输出 y-websocket 连接、重连、收发方向、消息类型和字节数
- 独立 `IoCollabSocketTransport` 管理连接和 App 生命周期
- 最大 10 秒指数退避重连、20 秒 Sync Step 1 重同步
- 30 秒无入站消息看门狗，回到前台时快速恢复连接
- `OffsetKind::Utf16`，与 Dart/Yjs 的文本下标一致
- `gc: false` 对应的 `skip_gc: true`
- SQLite 增量 Update 日志，应用重启后离线恢复
- 本地内存版标准 y-websocket 测试服务
- 同一 room 的多客户端实时同步
- 旧版 `cses_demo_text` SQLite 数据以零文本复制方式挂载为 paragraph 块

当前第二阶段使用手机 Demo 自有的块 Schema：

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

这套结构用于先验证两个手机端之间的块级离线协同。它不会默认连接 CSES
生产环境，也不会向真实 BlockCraft 文档写入未知结构；桌面 BlockCraft Schema
兼容仍需后续基于桌面端 fixtures 实现。

## 运行

首次构建移动端 Rust 库时安装目标工具链：

```bash
rustup target add \
  aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
  aarch64-linux-android armv7-linux-androideabi \
  i686-linux-android x86_64-linux-android
```

先启动测试服务：

```bash
cargo run --manifest-path server/Cargo.toml
```

再安装依赖并启动 Flutter：

```bash
flutter pub get
flutter devices
flutter run -d <android-device-id>
# iOS 先生成 SPM 所需的 Rust XCFramework
scripts/ios.sh run -d <ios-device-id>
```

启动后先在连接管理页确认 WS 地址和 room，再点击“进入协同编辑”打开独立
编辑页面。返回连接页不会销毁协同控制器或断开连接。

当前开发机检测到的两台真机可以分别在两个终端启动：

```bash
flutter devices
flutter run -d <android-device-id>
scripts/ios.sh run -d <ios-device-id>
```

iPhone 首次运行需要在 Xcode 中配置开发者签名。两台手机默认使用
`ws://196.168.1.109:1234/demo-room`，无需修改 room。

宿主 Flutter 最低版本为 **3.44.0**，Dart 最低版本为 **3.12.0**；`rust_builder` 支持 Flutter 3.44.0 起。
依赖按 Flutter 3.44.9 验证，锁定版本见 `pubspec.lock`。Flutter SDK 固定的依赖与工作区插件的
主版本约束继续由依赖解析器管理。`rust_builder` 使用 ffi 2.2.0、ffigen 21.0.0；
ffigen 22/23 的传递依赖要求 meta >=1.19，与该 Flutter SDK 固定的 meta 1.18 不兼容。
FRB 的 Dart 库、Rust 库和代码生成器统一为 2.13.0。修改 Rust API 后使用
`flutter_rust_bridge_codegen` 2.13.0 执行 `flutter_rust_bridge_codegen generate`，再重建原生库。
iOS 最低版本为 14.0。宿主只使用 SPM，不需要 CocoaPods；`rust_builder/ios` 提供 SPM 接入。
使用 Flutter 3.44.9 默认启用的 SPM 支持，无需额外配置开关。
Flutter 生成的 `FlutterGeneratedPluginSwiftPackage` 管理插件，Rust 插件通过
`rust_builder/ios/cses_collab_core/Package.swift` 引用本地动态 XCFramework。

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

`rust_builder` 保留 `.podspec` 和 Cargokit 构建脚本，供其他使用 CocoaPods 的宿主接入；
本宿主不提供 CocoaPods 回退配置。

已验证的 Android Debug APK 位于：

```text
dist/cses-mobile-collab-demo-debug.apk
```

另开一个终端，再启动一个设备或模拟器，并保持 room 为 `demo-room`，
即可验证双端同步。

建议按以下顺序验收当前块级阶段：

1. 手机 A 输入中文、Emoji 和多段 paragraph，手机 B 应实时出现；
2. 确认文档顶部显示默认封面和大号标题；编辑标题、替换或移除封面后，手机 B 应同步；
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

- 当前开发机及两个真机：`ws://196.168.1.109:1234`
- iOS Simulator 也可使用：`ws://127.0.0.1:1234`
- Android Emulator：`ws://10.0.2.2:1234`
- 更换网络后，真机需要填写开发机新的局域网 IP

### Android USB 真机连接故障排查

Android 真机通过 USB 调试，并将连接地址配置为
`ws://127.0.0.1:1234/demo-room` 时，需要使用 `adb reverse` 把手机的
`127.0.0.1:1234` 转发到开发机的 WebSocket 服务：

```bash
adb reverse tcp:1234 tcp:1234
adb reverse --list
```

`adb reverse` 映射不会永久保存。手机重新连接 USB、设备重启或 ADB 服务重启后，
映射可能丢失。此时即使开发机上的 WebSocket 服务仍在正常运行，客户端也会出现
以下错误：

```text
SocketException: Connection refused
endpoint=ws://127.0.0.1:1234/demo-room
```

遇到该错误时，先确认测试服务仍在运行。如果服务已经停止，在一个单独的终端中
重新启动：

```bash
cargo run --manifest-path server/Cargo.toml
```

再在另一个终端确认设备并重新建立端口映射：

```bash
adb devices
adb reverse tcp:1234 tcp:1234
adb reverse --list
```

然后点击应用内的“连接 / 重连”或重启应用。连接恢复后应看到：

```text
status=online event=socket-connected
endpoint=ws://127.0.0.1:1234/demo-room
```

因此，每次重新插拔 Android 真机后，都应检查并按需重新执行
`adb reverse tcp:1234 tcp:1234`。

关闭服务后仍可继续编辑；重新启动服务并点击“连接 / 重连”，客户端会通过
Yjs State Vector 自动补齐离线更新。客户端也会自动重连，手动按钮用于立即
重试或切换 WS 地址。

运行 `flutter run` 后可在终端或 IDE 控制台查看协议日志，例如：

```text
[y-websocket][...][STATE] status=online event=socket-connected endpoint=ws://.../demo-room
[y-websocket][...][OUT] sync-step-1 bytes=10 room=demo-room
[y-websocket][...][IN] sync-step-2 bytes=128 room=demo-room
[y-websocket][...][OUT] sync-update bytes=64 room=demo-room
```

日志不打印 CRDT Update 或 Awareness 的实际载荷，并在 Release 构建中默认关闭。

## 验证

```bash
cargo test --manifest-path rust/Cargo.toml
cargo check --manifest-path server/Cargo.toml
flutter test
flutter analyze
flutter build apk --debug
flutter build ios --debug --no-codesign
```

## 与 CSES 桌面端的边界

当前 Demo 验证的是相同的 CRDT 和 y-websocket 线协议，不是最终的
BlockCraft 语义 Schema。接入真实文档前需要从桌面端固化以下 fixtures：

1. 顶层 `Y.Map` 的真实名称；
2. root block、paragraph、heading、list 的 Y.Map/Y.Array/Y.Text 结构；
3. rich-text Delta attributes；
4. Awareness 的 user/status/cursor JSON；
5. `/doc/document/edit` 所需 dirty-block 快照。

当前已经验证 AppFlowy 顶层 paragraph、heading 和 list 到手机端块 Schema
的双向映射。后续将这层替换为 `BlockCraftSchemaAdapter`，对齐桌面端真实
root/block 数据结构，再逐步映射 rich-text attributes 和 table；
`dart:io` 网络传输层和 SQLite Update 日志不需要重写。

当前同步顶层块的类型、顺序、文本/URL、Todo 勾选、对齐和视觉缩进，以及 bold、italic、underline、
strikethrough、inline-code、textColor、backgroundColor、superscript、subscript 行内属性。当前缩进保持扁平块
Schema，仅表现为列表/Todo 的视觉层级，不会生成 AppFlowy 子节点。链接、图片和视频 URL 使用各块现有
Y.Text 载荷同步，不额外扩展 bridge 字段。语义嵌套列表、table、Awareness 光标与用户状态暂时不会同步；
提及、文件、表格等入口仍显示“后续阶段”提示，不会插入 Rust Schema 无法保存的节点。

## 编辑页面移植

编辑器页面已经从连接管理页拆出：

- `lib/src/ui/collaborative_editor_page.dart`：全屏编辑页、连接状态、撤销/重做；
- `lib/src/ui/editor_shortcut_toolbar.dart`：键盘快捷栏和“添加”面板；
- `lib/src/collab/collab_controller.dart`：编辑状态及协同生命周期；
- `lib/src/collab/appflowy_block_editor_adapter.dart`：AppFlowy transaction 与
  Rust/Yrs 块 Schema 的双向适配。

业务 App 创建并持有 `CollabController`，完成 `initialize()` 后，通过
`CollaborativeEditorPage(collab: controller)` 打开编辑页即可。页面退出时
不要销毁仍需复用的 controller；由创建它的上层页面或依赖注入容器统一释放。

## 非生产能力

测试服务仅在内存中保存数据，没有鉴权、服务端持久化、限流和 Awareness。
这些能力应继续使用现有 CSES 服务，Demo server 只用于本地协议验证。

为了访问本地 `ws://` 服务，Demo 临时放宽了 Android cleartext 和 iOS ATS。
接入业务环境时必须使用 `wss://`，并移除
`android:usesCleartextTraffic="true"` 与 `NSAllowsArbitraryLoads`。
