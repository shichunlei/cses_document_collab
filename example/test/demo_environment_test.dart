import 'package:cses_common/runtime/config/config.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_mobile_collab_demo/src/demo/demo_environment.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/common_login_harness.dart';
import 'support/test_environment_bundle.dart';

/// 验证资源读取、JSON 失败、空配置与 origin 边界，不读取本机真实配置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('origins support ports and reject paths or embedded secrets', () {
    expect(
      DemoEnvironment.origin('https://api.example.test:8443/', 'API').origin,
      'https://api.example.test:8443',
    );
    for (final value in [
      '',
      'api.example.test',
      'ftp://api.example.test',
      'https://user:secret@api.example.test',
      'https://api.example.test/path',
      'https://api.example.test?token=secret',
      'https://api.example.test#fragment',
    ]) {
      expect(
        () => DemoEnvironment.origin(value, 'API'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'safe error',
            '请配置有效的 API',
          ),
        ),
      );
    }
  });

  test(
    'empty JSON leaves credentials empty and refuses built-in hosts',
    () async {
      await DemoEnvironment.load(bundle: TestEnvironmentBundle('{}'));
      expect(DemoEnvironment.username, isEmpty);
      expect(DemoEnvironment.password, isEmpty);
      expect(DemoEnvironment.environment, 'pre');
      expect(DemoEnvironment.requireMediaDomain, throwsFormatException);
      await expectLater(
        DemoEnvironment.configureCommon(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'missing variable',
            '请配置有效的 CSES_API_URL',
          ),
        ),
      );
    },
  );

  test(
    'invalid or missing assets clear previous values without exposing content',
    () async {
      for (final bundle in [
        TestEnvironmentBundle('secret invalid json'),
        TestEnvironmentBundle('[]'),
        TestEnvironmentBundle('{"CSES_DEFAULT_PASSWORD":123}'),
        TestEnvironmentBundle('{}', missing: true),
      ]) {
        await loadTestEnvironment();
        expect(DemoEnvironment.username, 'fixture-account');
        await expectLater(
          DemoEnvironment.load(bundle: bundle),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'safe error',
              '无法读取 .env.json，请检查文件是否存在且为字符串值的 JSON 对象',
            ),
          ),
        );
        expect(DemoEnvironment.username, isEmpty);
        expect(DemoEnvironment.password, isEmpty);
        expect(DemoEnvironment.apiUrl, isEmpty);
      }
    },
  );

  test(
    'env replaces Common address and credential defaults on every login',
    () async {
      final harness = CommonLoginHarness();
      await harness.install();
      addTearDown(harness.uninstall);
      await DemoEnvironment.configureCommon();
      expect(Config().baseUrl, DemoEnvironment.apiUrl);
      expect(DemoEnvironment.websocketUrl, isNull);
      expect(Config().webSocket, Config().envType.websocketHost);
      ctx.websocketHost = 'wss://session.example.test/ws';
      expect(DemoEnvironment.websocketUrl, ctx.websocketHost);
      await DemoEnvironment.configureCommon();
      expect(Config().webSocket, Config().envType.websocketHost);
      expect(ctx.websocketHost, 'wss://session.example.test/ws');
      expect(Config().defaultUsername, DemoEnvironment.username);
      expect(Config().defaultPassword, DemoEnvironment.password);
      expect(Config().restHost, Uri.parse(DemoEnvironment.apiUrl).authority);
      expect(Config().protocol, Uri.parse(DemoEnvironment.apiUrl).scheme);
      expect(harness.requests, isEmpty);
    },
  );
}
