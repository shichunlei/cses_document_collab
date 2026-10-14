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
- `CollabHostServices` 注入 ID 工厂、错误报告和可选 `EditorMediaUploadService`。没有上传服务时只显示 URL 输入；上传实现持有宿主认证。现有接口使用 Dio CancelToken 表达取消。
- `localDraft` 是独立模式，保留旧 demo schema 和头部迁移；默认封面由宿主传入。正式模式不经过草稿初始化、不创建业务根/标题/封面。
- FRB、Rust 原始 API、EditorState 和内部块类型是包内实现，宿主使用公开控制器状态/命令及编辑页。不要从 src 导入。

## 原生构建与测试

Android 通过本包 android/Cargokit 构建 rust。安装对应 Rust Android targets 和 NDK 后，从最终 App 执行 Flutter build。原生库名仍是 cses_collab_core。

iOS 使用 `ios/cses_document_collab/Package.swift` 的本地动态 XCFramework。在 Flutter/Xcode 解析 SPM 之前执行：

```bash
/path/to/cses_document_collab/tool/build_rust_ios.sh debug
# Archive 前使用 release；生成物不进入 Git。
```

原生依赖由 Cargo.lock 固定，libc 显式固定 0.2.186 以兼容 backtrace 在 iOS 上使用的 dyld 声明。

所需 targets 为 aarch64-apple-ios、aarch64-apple-ios-sim、x86_64-apple-ios。构建工具以包位置为根，不依赖调用方 cwd。CocoaPods podspec 也随包保留，当前 demo 验证 SPM；CocoaPods 单独标为未验证。

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

包保留已有块支持范围、未知数据保护和模型只读规则。上传、私有资源鉴权、业务元数据、服务端保存及租户权限由宿主/服务端提供，真实环境联调须单独验收。
