import 'dart:convert';

import 'package:cses_common/runtime/config/config.dart';
import 'package:cses_common/runtime/config/env_type.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:flutter/services.dart';

/// Demo 启动时从 `.env.json` asset 读取的环境配置，API 地址无内置兜底。
/// 配置只由宿主读取，不进入协同文档；主连接地址由 Common 登录上下文提供。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/demo_environment.dart';
/// import 'package:flutter/widgets.dart';
///
/// Future<void> loadEnvironment() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await DemoEnvironment.load(); // 创建页面前加载；无外部资源需要释放。
/// }
/// ```
abstract final class DemoEnvironment {
  /// 应用启动时读取的配置快照；页面创建前加载，不在登录期间重新读取。
  static Map<String, String> _values = const {};

  /// 从应用资源中的 `.env.json` 读取配置，完成后页面可同步访问各字段。
  /// [bundle] 为借用的资源加载器，默认 rootBundle，测试可注入合成配置；不由此处释放。
  /// 仅在创建页面前调用；失败会清空快照并抛出不含原始内容的 [FormatException]。
  /// 修改文件后需重新运行应用以更新资源及页面状态。
  static Future<void> load({AssetBundle? bundle}) async {
    try {
      final raw = await (bundle ?? rootBundle).loadString('.env.json', cache: false);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded.values.any((value) => value is! String)) {
        throw const FormatException();
      }
      _values = Map<String, String>.unmodifiable(decoded.cast<String, String>());
    } catch (_) {
      _values = const {};
      throw const FormatException('无法读取 .env.json，请检查文件是否存在且为字符串值的 JSON 对象');
    }
  }

  /// 可选预填用户名；未配置时为空，输入状态由登录页持有。
  static String get username => _values['CSES_DEFAULT_USERNAME'] ?? '';

  /// 可选预填密码；未配置时为空，不写入偏好存储。
  static String get password => _values['CSES_DEFAULT_PASSWORD'] ?? '';

  /// Common 环境标识，用于 header、账号缓存分区与内置主连接回退；API 地址独立配置。
  static String get environment => _values['CSES_ENV'] ?? 'pre';

  /// 必填 API origin，包含 http/https 协议与可选端口。
  static String get apiUrl => _values['CSES_API_URL'] ?? '';

  /// 借用 Common 当前主连接地址；登录上下文解析前或清理后可能为 null。
  /// 每次访问读取 ctx.websocketHost，不从 env 读取，也不创建或持有连接。
  static String? get websocketUrl => ctx.websocketHost;

  /// 必填文档站点 origin，包含 http/https 协议与可选端口。
  static String get documentUrl => _values['CSES_DOCUMENT_URL'] ?? '';

  /// 上传资源 CDN 域名后缀；实际域名为 bucket 加此后缀，缺失时禁止上传。
  static String get mediaDomain => _values['CSES_MEDIA_DOMAIN'] ?? '';

  /// 将已加载的 env 写入 Common 的公开配置字段，完成前不得访问 HTTP 单例。
  /// 缺失或无效配置抛出仅含变量名的 [FormatException]，不回显配置值。
  /// 保留 Common 的环境元数据与主连接回退配置，覆盖 API 地址和默认凭证。
  /// 此方法先于登录执行，不读取或回写尚未解析的主连接地址；该地址在登录成功后校验。
  /// 重复调用会重新应用配置。
  static Future<void> configureCommon() async {
    final api = origin(apiUrl, 'CSES_API_URL');
    origin(documentUrl, 'CSES_DOCUMENT_URL');
    final env = EnvType.values.where((value) => value.name == environment).firstOrNull;
    if (env == null) throw const FormatException('请配置有效的 CSES_ENV');
    final config = await Config().loadFromAsset(env, 'bct');
    config
      ..restHost = api.authority
      ..protocol = api.scheme
      ..baseUrl = api.origin
      ..defaultUsername = username
      ..defaultPassword = password;
  }

  /// 校验 [value] 是 HTTP origin；[name] 仅用于错误提示，不输出配置原值。
  /// 允许端口及单个结尾斜线；路径、凭证、查询及 fragment 均拒绝。
  static Uri origin(String value, String name) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw FormatException('请配置有效的 $name');
    }
    return uri;
  }

  /// 返回上传 CDN 后缀；缺失或包含路径、协议、端口时在上传前拒绝。
  static String requireMediaDomain() {
    final uri = Uri.tryParse('https://$mediaDomain');
    if (mediaDomain.isEmpty ||
        uri == null ||
        uri.host != mediaDomain ||
        uri.hasPort ||
        uri.path.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请配置有效的 CSES_MEDIA_DOMAIN');
    }
    return mediaDomain;
  }
}
