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

代码块/图片题注、未知实体与localDraft保持原保护范围；同步任务参与人业务副作用尚未提供端口。历史Android头像与桌面联调见根仓库`docs/verification/user-mention-20261014.json`；本次UI迁移尚未重做真机/桌面联调。

## 会议、任务和文档提及（普通正文）

正式 `{mention: name}` 配合 `mentionType=meeting/task/doc` 和稳定 `mentionId`（兼容历史 `d:` 前缀），在段落、标题、列表、引用及高亮正文中显示类型图标+名称，不附加@，不再降级为只读占位。每个对象仍占一个UTF-16位置；普通文字、用户头像和公式可混排。点击可查看共享名称/ID并删除提及，预览禁止删除；独立撤销/重做恢复原始实体属性。姓名最长20000 UTF-16单元，ID最长512 UTF-8字节，非用户实体属性JSON最大65536字节。

原始编号、状态、文档类型、任务扩展等属性完整保留，嵌套对象的JSON排序稳定；属性快照仅供删除后恢复，普通编辑不回放陈旧业务状态。远端类型、身份、属性或同段正文变化使过期操作失效。新增搜索仍是人员入口，尚无会议/任务/文档选择器、业务详情跳转或业务实体修改；这三类提及保持部分支持，不代表对应会议/任务卡片块已适配。代码块和图片题注、未知实体与localDraft继续遵循保护边界。验证与真机联调记录见仓库 `docs/block-adaptation.md`。


## 宿主统一提及点击回调

通过公开入口的 `CollabHostServices.onMentionTap` 接管用户、会议、任务、文档点击。参数 `CollabMentionTap` 包含 `type`（`CollabMentionType.user/meeting/task/doc`）、`id`、`name` 和 `attributes`。名称是共享正文原名，空名称仍为空；属性来自Y.Text，保留历史d:键、格式及未知扩展，不从人员/实体详情接口拼装，不包含移动编辑器的cses私有属性。所有嵌套Map/List均深复制且只读，宿主可独立保留事件。`mention.toJson()`返回`type/id/name/attributes`，其中`type`为`user/meeting/task/doc`字符串，可直接`jsonEncode(mention)`；每次返回独立顶层Map，内部属性沿用只读快照。

用户提及仅在配置回调时响应点击，编辑包不提供用户资料面板；未配置时不处理点击，也不暂停输入或恢复光标。会议/任务/文档未配置回调时继续使用实体信息面板；配置后点击由宿主接管，不同时打开内置面板，预览也允许导航。支持同步或异步处理；导航应返回直到详情退场完成的Future。回调期间暂停正文输入并忽略同编辑器的重复点击，完成后仅向仍有效的原页面恢复焦点。同步/异步异常向原宿主onError报告并在有效页面提示，不补开默认面板；已关闭或被新会话替代的编辑器不恢复键盘。宿主仍负责业务鉴权、跨账号异步失效、路由和外部资源生命周期。

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

用户点击面板移除、缺省不响应及统一回调兼容验证见根仓库`docs/verification/mention-user-tap-only-20261015.json`。


## 会议引用卡片

正式 `meeting` 是无正文、无子块的引用卡片，保留 `props.meetingId/title/number`。
移动端先使用共享标题和编号，空标题显示“未命名会议”。可通过宿主`loadMeetingCard`加载本地会议详情，展示状态、开始时间（设备本地时区）、主持人和参与人数；业务标题/编号可覆盖本地展示，但不写回共享props。
“更多→会议”调用宿主注入的 `pickMeetingReference` 选择/创建会议引用；未注入时隐藏新增入口。包不提供会议输入表单或业务创建逻辑；卡片底部独立的“删除引用”按钮直接移除本文档引用，无需打开面板，业务会议不受影响。卡片不再显示“编辑引用”入口。
插入按稳定正文位置定位，支持根/高亮容器、空段替换与非空段后插入、撤销/重做。
引用修改工具保留逐字段补丁和版本校验；卡片删除按稳定块ID和展示时属性校验，远端变化或撤权拒绝过期删除。删除父容器最后一项时补空段落，支持独立撤销/重做；预览/只读隐藏删除按钮。
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

未配置加载器时保留共享引用并显示“状态未知”；明确返回null表示会议不存在，`Delete`表示已删除，二者均禁用主按钮。未知状态不伪造未开始；加载中或失败也禁用主按钮，失败显示重试并向原宿主报告。Demo通过`lib/src/demo/cses_meeting_card_service.dart`及Common的`POST /meeting/getDetail`加载详情，前后校验账号、企业和会话。

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

历史整卡点击、直接删除与键盘抑制验证见`docs/verification/meeting-card-actions-20261015.json`；当前状态配色、按钮点击及底部删除布局已取代整卡点击，验证见根仓库`docs/verification/meeting-card-status-20261015.json`。

主按钮仅回调宿主、执行前后不新增详情请求的后续验证见`docs/verification/meeting-card-callback-only-20261015.json`。
