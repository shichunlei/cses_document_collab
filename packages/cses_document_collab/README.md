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

包保留已有块支持范围、未知数据保护和模型只读规则。正式正文（含代码块）出现未适配行内对象时，仅将所在段落投影为不可编辑占位，完整保留原始Y.Text与属性；其他已适配块继续编辑，含占位的父容器不可连带删除。未知类型仍保持保护，用户、会议、任务、文档四类提及的普通正文支持另见下文，锁、修订和图片题注等既有只读保护仍生效。上传、私有资源鉴权、业务元数据、服务端保存及租户权限由宿主/服务端提供，真实环境联调须单独验收。

## 人员提及端口

宿主通过公开入口实现 `CollabMentionDirectory.search(keyword)` 与 `load(userId)`，并传入 `CollabHostServices(mentionDirectory: directory)`。搜索返回当前企业的真实 `CollabMentionUser` 列表，空关键词返回初始人员；资料不存在返回null、请求失败抛异常。编辑包不持有账号或HTTP资源，也不释放宿主目录；宿主必须校验账号/企业切换，不能复用旧会话缓存。Demo的Common实现及完整初始化示例见宿主源码和根README。

正文只同步显示名/稳定ID，人员部门/职位属于本地资料。没有目录时新增入口说明缺少服务，既有用户仍可展示、复制或按权限删除；原子、历史和只读范围详见根README与 `docs/block-adaptation.md`。代码块/图片题注、未知实体提及与localDraft保持保护；会议/任务/文档普通正文支持见下文。同步任务参与人业务副作用尚未提供端口。

人员头像由编辑器按 `https://face.jinqidongli.com/{userid}/{userid}.jpg` 拼接并本地加载，支持宿主 `avatarUrl` 覆盖；正文仅存姓名/ID。正文、列表及资料卡均使用圆形裁切，加载或失败回退首字，不附加认证信息。Android真实头像与提及操作、桌面双向同步验收见根仓库 `docs/verification/user-mention-20261014.json`；桌面观察由用户完成，iOS头像尚未验证。


## 会议、任务和文档提及（普通正文）

正式 `{mention: name}` 配合 `mentionType=meeting/task/doc` 和稳定 `mentionId`（兼容历史 `d:` 前缀），在段落、标题、列表、引用及高亮正文中显示类型图标+名称，不附加@，不再降级为只读占位。每个对象仍占一个UTF-16位置；普通文字、用户头像和公式可混排。点击可查看共享名称/ID并删除提及，预览禁止删除；独立撤销/重做恢复原始实体属性。姓名最长20000 UTF-16单元，ID最长512 UTF-8字节，非用户实体属性JSON最大65536字节。

原始编号、状态、文档类型、任务扩展等属性完整保留，嵌套对象的JSON排序稳定；属性快照仅供删除后恢复，普通编辑不回放陈旧业务状态。远端类型、身份、属性或同段正文变化使过期操作失效。新增搜索仍是人员入口，尚无会议/任务/文档选择器、业务详情跳转或业务实体修改；这三类提及保持部分支持，不代表对应会议/任务卡片块已适配。代码块和图片题注、未知实体与localDraft继续遵循保护边界。验证与真机联调记录见仓库 `docs/block-adaptation.md`。


## 宿主统一提及点击回调

通过公开入口的 `CollabHostServices.onMentionTap` 接管用户、会议、任务、文档点击。参数 `CollabMentionTap` 包含 `type`（`CollabMentionType.user/meeting/task/doc`）、`id`、`name` 和 `attributes`。名称是共享正文原名，空名称仍为空；属性来自Y.Text，保留历史d:键、格式及未知扩展，不从人员/实体详情接口拼装，不包含移动编辑器的cses私有属性。所有嵌套Map/List均深复制且只读，宿主可独立保留事件。

未配置回调时保持原人员资料/实体信息面板；配置后点击由宿主接管，不同时打开内置面板，预览也允许导航。支持同步或异步处理；导航应返回直到详情退场完成的Future。回调期间暂停正文输入并忽略同编辑器的重复点击，完成后仅向仍有效的原页面恢复焦点。同步/异步异常向原宿主onError报告并在有效页面提示，不补开默认面板；已关闭或被新会话替代的编辑器不恢复键盘。宿主仍负责业务鉴权、跨账号异步失效、路由和外部资源生命周期。

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

四类原始属性JSON均限制为65536字节；正式投影完整传递，未就绪或损坏的属性拒绝派发并报告失败，不制造原始属性。新插入用户的身份快照立即可用；原有手工用户投影仍可不带快照使用默认面板。编辑包不内置业务路由，回调接管时默认面板的删除入口由宿主选择如何提供。
