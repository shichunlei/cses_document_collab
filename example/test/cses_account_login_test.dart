import 'dart:async';

import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/config/config.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/preferences/sp_util.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/demo/demo_environment.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_demo_host.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_host.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/common_login_harness.dart';

/// 验证登录经过真实 Common HTTP、上下文和登出边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  setUp(() async {
    harness = CommonLoginHarness();
    await harness.install();
  });
  tearDown(() => harness.uninstall());

  test(
    'Common login initializes headers and context before handing off',
    () async {
      Config().baseUrl = 'https://stale.test';
      await const CsesAccountLogin().login(' account ', ' password ');
      final request = harness.requests.single;
      expect(request.uri.toString(), 'https://api.example.test/User/login');
      expect(request.method, 'POST');
      expect(request.data, {'userName': 'account', 'password': ' password '});
      expect(request.headers, containsPair('deviceId', 'native-device'));
      expect(request.headers, containsPair('appType', 'bct'));
      expect(request.headers, containsPair('envType', 'pre'));
      expect(request.headers, containsPair('appVersion', '1.0.0'));
      expect(request.headers['osVersion'], isNotNull);
      expect(request.headers['cpuVersion'], isNotNull);
      expect(ctx.cookieId, 'server-cookie');
      expect(User().userId, 'server-user');
      expect(User().companyId, 'server-company');
      expect(ctx.websocketHost, 'wss://example.test/deployment/ws');
      expect(User().name, '测试用户');
      expect(ctx.site, 'jqdl');
      expect(ctx.pictureDomain, 'https://picture.example.test/KEY');
      expect(ctx.videoDomain, 'https://video.example.test/KEY');
      expect(ctx.attachmentDomain, 'https://attachment.example.test/KEY');
      expect(User().currentCompany?.companyName, '测试企业');
      expect(SpUtil.getString('password'), isEmpty);

      // 登录后的请求继续使用同一 Common Dio，并自动带上新身份。
      await HttpManager.getInstance().post('/document/probe');
      final next = harness.requests.last;
      expect(next.headers['cookieId'], 'server-cookie');
      expect(next.headers['companyId'], 'server-company');
      expect(next.headers['deviceId'], request.headers['deviceId']);
    },
  );

  test('empty credentials and missing Common device never send HTTP', () async {
    for (final args in [('', 'secret'), ('account', '')]) {
      await expectLater(
        const CsesAccountLogin().login(args.$1, args.$2),
        throwsA(isA<CsesLoginFailure>()),
      );
    }
    harness.deviceId = ' ';
    await expectLater(
      const CsesAccountLogin().login('account', 'secret'),
      throwsA(isA<CsesLoginFailure>()),
    );
    expect(harness.requests, isEmpty);
    expect(ctx.cookieId, isNull);
  });

  test('business failure does not inject an authenticated context', () async {
    harness.respond = (_) =>
        jsonResponse({'isSuccess': false, 'message': '密码错误'});
    await expectLater(
      const CsesAccountLogin().login('account', 'wrong'),
      throwsA(
        isA<CsesLoginFailure>().having((e) => e.message, 'message', '密码错误'),
      ),
    );
    expect(ctx.cookieId, isNull);
    expect(User().companyId, isEmpty);
  });

  test(
    'storage initialization failure still clears Common login on exit',
    () async {
      await const CsesAccountLogin().login('account', 'secret');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'storage-unavailable'),
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final host = DemoDocumentHost();
      await host.initialize();
      expect(host.error, isNotNull);
      expect(host.controller, isNull);
      await host.close();
      expect(ctx.cookieId, isNull);
      expect(User().companyId, isEmpty);
      expect(ctx.deviceId, 'native-device');
    },
  );

  test(
    'incomplete and invalid resolved context is cleared before retry',
    () async {
      for (final key in ['cookieId', 'userId', 'organizes']) {
        harness.respond = (_) => jsonResponse(success()..remove(key));
        await expectLater(
          const CsesAccountLogin().login('account', 'secret'),
          throwsA(isA<CsesLoginFailure>()),
        );
        expect(ctx.cookieId, isNull);
        expect(User().userId, isEmpty);
        expect(User().companyId, isEmpty);
        expect(ctx.authorities, isEmpty);
      }
      for (final host in [
        'https://invalid.test/ws',
        'wss://example.test/ws?cookieId=secret',
        'wss://example.test/ws?deployment=a',
        'wss://example.test/ws#fragment',
        'wss://user:secret@example.test/ws',
      ]) {
        harness.respond = (_) =>
            jsonResponse(success()..['webConfig'] = {'websocketHost': host});
        await expectLater(
          const CsesAccountLogin().login('account', 'secret'),
          throwsA(isA<CsesLoginFailure>()),
        );
        expect(ctx.cookieId, isNull);
      }
      harness.respond = (_) => jsonResponse(success());
      await const CsesAccountLogin().login('account', 'secret');
      expect(ctx.cookieId, 'server-cookie');
    },
  );

  test(
    'Common chooses cached organization and supplies environment WS default',
    () async {
      await SpUtil.setString('server-user-pre', 'remembered');
      harness.respond = (_) => jsonResponse(
        success()
          ..remove('companyId')
          ..remove('webConfig')
          ..['organizes'] = [
            {'companyId': 'teacher'},
            {'companyId': 'course', 'isCourse': true},
            {'companyId': 'ordinary'},
            {'companyId': 'remembered'},
          ],
      );
      await const CsesAccountLogin().login('account', 'secret');
      expect(User().companyId, 'remembered');
      expect(User().currentCompany?.companyId, 'remembered');
      expect(ctx.websocketHost, Config().webSocket);
      expect(DemoEnvironment.websocketUrl, ctx.websocketHost);
    },
  );

  test(
    'network and gateway errors use Common mapping without credentials',
    () async {
      for (final type in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.connectionError,
      ]) {
        harness.respond = (options) => throw DioException(
          requestOptions: options,
          type: type,
          message: 'secret',
        );
        await expectLater(
          const CsesAccountLogin().login('account', 'secret'),
          throwsA(
            isA<CsesLoginFailure>().having(
              (e) => e.message.contains('secret'),
              'no password',
              false,
            ),
          ),
        );
        expect(ctx.cookieId, isNull);
      }
      harness.respond = (_) => jsonResponse({'isSuccess': false}, status: 503);
      await expectLater(
        const CsesAccountLogin().login('account', 'secret'),
        throwsA(
          isA<CsesLoginFailure>().having(
            (e) => e.message,
            'Common maintenance',
            '服务维护中，请稍后重试',
          ),
        ),
      );
    },
  );

  test('late login response cannot overwrite a newer context', () async {
    final reply = Completer<ResponseBody>();
    final sent = Completer<void>();
    var active = true;
    harness.respond = (_) {
      sent.complete();
      return reply.future;
    };
    final result = const CsesAccountLogin().login(
      'account',
      'secret',
      isActive: () => active,
    );
    await sent.future;
    active = false;
    ctx.cookieId = 'new-session';
    reply.complete(jsonResponse(success()));
    await expectLater(result, throwsA(isA<CsesLoginFailure>()));
    expect(ctx.cookieId, 'new-session');
    expect(User().companyId, isEmpty);
  });

  test(
    'logout clears Common identity but retains app device for next login',
    () async {
      await const CsesAccountLogin().login('account', 'secret');
      const CsesDemoHost().close();
      expect(ctx.cookieId, isNull);
      expect(User().userId, isEmpty);
      expect(User().companyId, isEmpty);
      expect(ctx.deviceId, 'native-device');
      harness.respond = (_) =>
          jsonResponse(success()..['cookieId'] = 'new-cookie');
      await const CsesAccountLogin().login('account', 'secret');
      expect(ctx.cookieId, 'new-cookie');
      expect(harness.requests.last.headers['cookieId'], isNull);
    },
  );
}
