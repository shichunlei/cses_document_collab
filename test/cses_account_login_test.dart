import 'dart:async';
import 'dart:io';
import 'package:cses_mobile_collab_demo/src/collab/cses_account_login.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> success() => {
  'isSuccess': true,
  'cookieId': 'server-cookie',
  'userId': 'server-user',
  'companyId': 'server-company',
  'name': '测试用户',
  'webConfig': {'websocketHost': 'wss://example.test/deployment/ws'},
};

void main() {
  test(
    'SaaS password contract uses one device and derives identity from response',
    () async {
      final login = CsesAccountLogin(
        deviceIdProvider: () async => 'native-device',
        request: (body, deviceId) async {
          expect(body, {'userName': 'account', 'password': ' password '});
          expect(deviceId, 'native-device');
          return success();
        },
      );
      final session = await login.login(' account ', ' password ');
      expect(session.settings.cookieId, 'server-cookie');
      expect(session.settings.userId, 'server-user');
      expect(session.settings.companyId, 'server-company');
      expect(session.settings.documentId, csesDemoDocumentId);
      expect(session.settings.websocketUrl, 'wss://example.test/deployment/ws');
      expect(session.displayName, '测试用户');
    },
  );

  test(
    'no HTTP request for empty credentials or missing native device',
    () async {
      var calls = 0;
      final login = CsesAccountLogin(
        deviceIdProvider: () async => null,
        request: (_, _) async {
          calls++;
          return success();
        },
      );
      await expectLater(
        login.login('', 'secret'),
        throwsA(isA<CsesLoginFailure>()),
      );
      await expectLater(
        login.login('account', ''),
        throwsA(isA<CsesLoginFailure>()),
      );
      await expectLater(
        login.login('account', 'secret'),
        throwsA(isA<CsesLoginFailure>()),
      );
      expect(calls, 0);
    },
  );

  test('rejected or incomplete login cannot produce a WS session', () {
    expect(
      () => CsesAccountSession.fromResponse({
        'isSuccess': false,
        'message': '密码错误',
      }),
      throwsA(
        isA<CsesLoginFailure>().having((e) => e.message, 'message', '密码错误'),
      ),
    );
    for (final key in ['cookieId', 'userId', 'companyId']) {
      final response = success()..remove(key);
      expect(
        () => CsesAccountSession.fromResponse(response),
        throwsA(isA<CsesLoginFailure>()),
      );
    }
    final invalid = success()
      ..['webConfig'] = {'websocketHost': 'https://example.test'};
    expect(
      () => CsesAccountSession.fromResponse(invalid),
      throwsA(isA<CsesLoginFailure>()),
    );
  });

  test(
    'company fallback skips virtual teacher and prioritizes ordinary organization',
    () {
      final response = success()
        ..remove('companyId')
        ..remove('webConfig');
      response['organizes'] = [
        {'companyId': 'teacher'},
        {'companyId': 'course', 'isCourse': true},
        {'companyId': 'ordinary'},
      ];
      final session = CsesAccountSession.fromResponse(response);
      expect(session.settings.companyId, 'ordinary');
      expect(session.settings.websocketUrl, 'wss://ws-pre.jinqidongli.com/ws');
    },
  );

  test(
    'network failures show actionable messages without request credentials',
    () async {
      for (final error in [
        TimeoutException('secret'),
        const SocketException('secret'),
      ]) {
        final login = CsesAccountLogin(
          deviceIdProvider: () async => 'device',
          request: (_, _) async => throw error,
        );
        await expectLater(
          login.login('account', 'secret'),
          throwsA(
            isA<CsesLoginFailure>().having(
              (e) => e.message.contains('secret'),
              'no password',
              false,
            ),
          ),
        );
      }
    },
  );
}
