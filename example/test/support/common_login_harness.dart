import 'dart:async';
import 'dart:convert';

import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/config/config.dart';
import 'package:cses_common/runtime/config/env_type.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/preferences/sp_util.dart';
import 'package:cses_common/runtime/runtime_fields.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_environment_bundle.dart';

/// 仅替换 Common Dio 的传输和原生通道，保留真实配置、header、错误映射与上下文解析。
class CommonLoginHarness implements HttpClientAdapter {
  /// 创建无网络传输的测试边界，默认返回 [success]。
  CommonLoginHarness();

  /// 实际经过 Common 拦截器的请求。
  final requests = <RequestOptions>[];

  /// 可覆盖响应或传输错误；异步响应可模拟页面销毁前后的竞态。
  FutureOr<ResponseBody> Function(RequestOptions) respond = (_) =>
      jsonResponse(success());

  /// 原生设备 ID；null/空白用于验证启动前置条件。
  String? deviceId = 'native-device';

  /// 测试前保留的 Common 传输，不关闭共享 Dio。
  late HttpClientAdapter _previousAdapter;

  /// 初始化偏好与原生通道，然后安装测试传输；由每项测试的 setUp 等待。
  Future<void> install() async {
    await loadTestEnvironment();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : true,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/package_info'),
      (_) async => {
        'appName': 'Collab Demo',
        'packageName': 'test.collab.demo',
        'version': '1.0.0',
        'buildNumber': '1',
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(RuntimeFields.channelName),
      (call) async =>
          call.method == RuntimeFields.getDeviceId ? deviceId : null,
    );
    await SpUtil.getInstance();
    await SpUtil.remove('DEVICE_ID');
    await SpUtil.remove('server-user-pre');
    User().clearData();
    ctx.site = null;
    ctx.websocketHost = null;
    ctx.deviceId = null;
    await Config().loadFromAsset(EnvType.pre, 'bct');
    HttpManager.getInstance();
    _previousAdapter = HttpManager.dio!.httpClientAdapter;
    HttpManager.dio!.httpClientAdapter = this;
  }

  /// 恢复 Common 传输并清理测试身份与平台替身。
  Future<void> uninstall() async {
    HttpManager.dio!.httpClientAdapter = _previousAdapter;
    User().clearData();
    ctx.site = null;
    ctx.websocketHost = null;
    ctx.deviceId = null;
    await SpUtil.remove('DEVICE_ID');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'plugins.flutter.io/shared_preferences',
      'dev.fluttercommunity.plus/package_info',
      RuntimeFields.channelName,
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  }

  /// 记录完成 header 注入的 [options]，通过 [respond] 返回结果；不使用请求流或取消。
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  /// 不持有实际 socket，无资源需要关闭；[force] 沿用 Dio 接口。
  @override
  void close({bool force = false}) {}
}

/// 生成具有实际 Common 企业选择所需 organizes 的成功响应。
Map<String, dynamic> success() => {
  'isSuccess': true,
  'cookieId': 'server-cookie',
  'userId': 'server-user',
  'userName': 'server-account',
  'companyId': 'server-company',
  'organizes': [
    {'companyId': 'server-company', 'companyName': '测试企业'},
  ],
  'name': '测试用户',
  'site': 'jqdl',
  'yrsSocket': '',
  'pictureDomain': 'https://picture.example.test/KEY',
  'videoDomain': 'https://video.example.test/KEY',
  'attachmentDomain': 'https://attachment.example.test/KEY',
  'webConfig': {'websocketHost': 'wss://example.test/deployment/ws'},
};

/// 将 [value] 编码为 Dio JSON 响应，[status] 可模拟网关失败。
ResponseBody jsonResponse(Object? value, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
