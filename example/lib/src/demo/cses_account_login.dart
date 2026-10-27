import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/config/config.dart';
import 'package:cses_common/runtime/config/env_type.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';

/// 可向用户显示的登录失败；不包含请求体或原始凭证。
final class CsesLoginFailure implements Exception {
  /// 使用可展示的 [message] 描述业务失败或上下文不可用。
  const CsesLoginFailure(this.message);

  /// 页面显示的错误文案。
  final String message;

  /// 返回页面可展示的错误文案。
  @override
  String toString() => message;
}

/// 按 SaaS 的顺序初始化 Common、请求登录，再由 Common 解析完整会话。
///
/// 请求地址、设备信息、公共 header 和错误映射均使用 Common 现有能力。
/// 不保存密码或登录账户快照，不创建 WebSocket；连接由登录后的文档宿主启动。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
///
/// await const CsesAccountLogin().login('account', 'password');
/// ```
class CsesAccountLogin {
  /// 创建登录服务；Common 单例由应用持有，无独立 HTTP 客户端需要释放。
  const CsesAccountLogin();

  /// 使用 [userName]、[password] 登录，用户名去空白，密码保持原样。
  ///
  /// [isActive] 在异步边界判断发起页面是否仍有效，省略时始终有效；取消或业务失败
  /// 抛出 [CsesLoginFailure]。配置和设备信息必须先于 HttpManager 首次访问初始化。
  /// 应用启动时须先初始化 Common 偏好存储，再开放登录入口。
  /// Future 成功返回时 User/ctx 已完整解析并通过文档连接校验；解析或校验失败会
  /// 清理本次注入的身份，防止页面重试沿用半完成的会话。
  Future<void> login(String userName, String password, {bool Function()? isActive}) async {
    if (userName.trim().isEmpty || password.isEmpty) {
      throw const CsesLoginFailure('请输入用户名和密码');
    }
    await Config().loadFromAsset(EnvType.pre, 'bct');
    await ctx.updateDeviceInfo();
    _checkActive(isActive);
    if (ctx.deviceId == null || ctx.deviceId!.trim().isEmpty) {
      throw const CsesLoginFailure('无法获取设备信息，请重试');
    }
    final response = await HttpManager.getInstance().post(
      '/User/login',
      params: {'userName': userName.trim(), 'password': password},
    );
    _checkActive(isActive);
    final value = response.data;
    if (value is! Map<String, dynamic>) {
      throw const CsesLoginFailure('登录服务返回了无法识别的数据');
    }
    if (value['isSuccess'] != true) {
      throw CsesLoginFailure('${value['message'] ?? value['error'] ?? '用户名或密码错误'}');
    }
    try {
      // resolveContext 同时选择企业并解析 ctx；不再另行推导、覆盖身份或 WS 地址。
      await User().resolveContext(value);
      _checkActive(isActive);
      _validateContext();
    } on FormatException {
      User().clearData();
      throw const CsesLoginFailure('登录上下文不完整，请使用已加入企业的账号或联系管理员');
    } catch (_) {
      User().clearData();
      rethrow;
    }
  }

  /// 校验 Common 当前登录和主连接入口，不创建或保存另一份连接配置。
  ///
  /// Common 主连接会自行追加 cookie 查询参数，因此服务端地址不得已有 query、
  /// fragment 或内嵌凭证；缺少用户/企业/会话或地址无效时抛出 FormatException。
  /// 文档 ID、数据库路径和缓存分区由文档宿主及 CollabDocumentConfig 负责。
  static void _validateContext() {
    final uri = Uri.tryParse(ctx.websocketHost ?? '');
    if ((ctx.cookieId ?? '').trim().isEmpty ||
        (User().userId ?? '').trim().isEmpty ||
        User().companyId.trim().isEmpty ||
        uri == null ||
        !const ['ws', 'wss'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('Common 登录上下文或主连接地址无效');
    }
  }

  /// [isActive] 返回 false 时中止后续副作用；不取消已经发出的网络请求。
  static void _checkActive(bool Function()? isActive) {
    if (isActive != null && !isActive()) {
      throw const CsesLoginFailure('登录已取消');
    }
  }
}
