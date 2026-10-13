import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cses_common/runtime/device/device_util.dart';
import 'package:cses_common/runtime/preferences/sp_util.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_connection_settings.dart';

/// 固定测试文档；登录仅改变身份，不创建或切换业务文档。
const csesDemoDocumentId = '6ac76e5375083c8c9f19cbd3';

/// 可注入的登录请求边界；[body] 含密码，调用方不得记录或持久化它。
typedef CsesLoginRequest =
    Future<Map<String, dynamic>> Function(
      Map<String, dynamic> body,
      String deviceId,
    );

/// 登录得到的内存会话；不保存密码，交由协同宿主建立唯一主连接。
final class CsesAccountSession {
  /// [settings] 是服务器返回的身份和连接地址，[displayName] 用于页面显示。
  const CsesAccountSession({required this.settings, required this.displayName});

  final CsesConnectionSettings settings;
  final String displayName;

  /// 按 SaaS `/User/login` 的顶层响应解析 [response]；失败时不产生可连接的会话。
  factory CsesAccountSession.fromResponse(Map<String, dynamic> response) {
    if (response['isSuccess'] != true) {
      throw CsesLoginFailure(
        '${response['message'] ?? response['error'] ?? '用户名或密码错误'}',
      );
    }
    String field(String key) =>
        response[key] is String ? (response[key] as String).trim() : '';
    final cookieId = field('cookieId');
    final userId = field('userId');
    var companyId = field('companyId');
    if (companyId.isEmpty) {
      // 与 SaaS User.resolveContext 一致，优先普通企业，跳过 teacher 虚拟身份。
      final organizes = (response['organizes'] as List? ?? const [])
          .whereType<Map>()
          .where(
            (item) =>
                item['companyId'] is String &&
                (item['companyId'] as String).isNotEmpty &&
                item['companyId'] != 'teacher',
          )
          .toList();
      if (organizes.isNotEmpty) {
        final company = organizes.firstWhere(
          (item) => item['isCourse'] != true,
          orElse: () => organizes.first,
        );
        companyId = company['companyId'] as String;
      }
    }
    if (cookieId.isEmpty || userId.isEmpty || companyId.isEmpty) {
      throw const CsesLoginFailure('登录响应缺少有效会话或企业信息，请使用已加入企业的账号');
    }
    final webConfig = response['webConfig'];
    final rawHost = webConfig is Map ? webConfig['websocketHost'] : null;
    var host = rawHost is String && rawHost.trim().isNotEmpty
        ? rawHost.trim()
        : 'wss://ws-pre.jinqidongli.com/ws';
    if (!host.contains('://')) host = 'wss://$host';
    final settings = CsesConnectionSettings(
      websocketUrl: host,
      cookieId: cookieId,
      companyId: companyId,
      userId: userId,
      documentId: csesDemoDocumentId,
    );
    try {
      settings.validate();
    } on FormatException {
      throw const CsesLoginFailure('登录响应中的连接配置无效，请联系管理员');
    }
    return CsesAccountSession(
      settings: settings,
      displayName: field('name').isNotEmpty ? field('name') : field('userName'),
    );
  }
}

/// 可向用户显示的登录失败；不包含请求体或原始凭证。
final class CsesLoginFailure implements Exception {
  const CsesLoginFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 复用 SaaS 密码登录的接口契约，使用本机 ID 注册登录与后续 WS 的同一设备身份。
///
/// 独立 Demo 不装配 SaaS 路由、权限或登录落盘流程。专用 HTTP 客户端不安装打印
/// 请求正文的调试拦截器，用户名、密码和 cookie 只在内存请求及会话中流转。
class CsesAccountLogin {
  /// [request] 和 [deviceIdProvider] 用于测试；生产默认访问 PRE 登录接口和 Common 设备工具。
  const CsesAccountLogin({this.request, this.deviceIdProvider});

  /// 登录请求替身；为空时调用 PRE 的 SaaS 账号密码接口。
  final CsesLoginRequest? request;

  /// 设备工具替身；为空时初始化 Common 偏好存储后读取本机 ID。
  final Future<String?> Function()? deviceIdProvider;

  /// 用 [userName]、[password] 登录；保留密码空白，失败时不启动 WS 或修改当前用户上下文。
  Future<CsesAccountSession> login(String userName, String password) async {
    if (userName.trim().isEmpty || password.isEmpty) {
      throw const CsesLoginFailure('请输入用户名和密码');
    }
    try {
      final String? deviceId;
      if (deviceIdProvider != null) {
        deviceId = await deviceIdProvider!();
      } else {
        await SpUtil.getInstance();
        deviceId = await DeviceUtils.getDeviceId();
      }
      if (deviceId == null || deviceId.trim().isEmpty) {
        throw const CsesLoginFailure('无法获取设备信息，请重试');
      }
      final response = await (request ?? _post)({
        'userName': userName.trim(),
        'password': password,
      }, deviceId);
      return CsesAccountSession.fromResponse(response);
    } on TimeoutException {
      throw const CsesLoginFailure('登录请求超时，请检查网络后重试');
    } on SocketException {
      throw const CsesLoginFailure('无法连接登录服务，请检查网络');
    } on HandshakeException {
      throw const CsesLoginFailure('登录服务安全连接失败，请稍后重试');
    } on HttpException {
      throw const CsesLoginFailure('登录服务响应异常，请稍后重试');
    } on FormatException {
      throw const CsesLoginFailure('登录服务返回了无法识别的数据');
    }
  }

  /// 向 SaaS PRE 的 [body] 提交账号密码；[deviceId] 与 WS 请求头一致，客户端在完成后关闭。
  static Future<Map<String, dynamic>> _post(
    Map<String, dynamic> body,
    String deviceId,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final request = await client.postUrl(
          Uri.parse('https://api-pre.jinqidongli.com/User/login'),
        );
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        final headers = <String, Object>{
          'appType': 'bct',
          'envType': 'pre',
          'deviceId': deviceId,
          'device': Platform.isIOS ? 'IOS' : 'Android',
          'appVersion': '1.0.0-collab-demo',
          'versionCode': 1,
          'osVersion': 'demo',
          'cpuVersion': 'unknown',
          'language': 'zh',
        };
        headers.forEach(request.headers.set);
        request.write(jsonEncode(body));
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          throw CsesLoginFailure('登录服务暂不可用（${response.statusCode}）');
        }
        final decoded = jsonDecode(await utf8.decoder.bind(response).join());
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        return decoded;
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }
}
