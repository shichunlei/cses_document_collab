import 'dart:async';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/common_login_harness.dart';

/// 验证 env 预填账号后的表单校验、单次提交和登录请求生命周期。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  setUp(() async {
    harness = CommonLoginHarness();
    await harness.install();
  });
  tearDown(() => harness.uninstall());
  testWidgets(
    'username/password only; validation, single submission and successful handoff',
    (tester) async {
      final reply = Completer<Map<String, dynamic>>();
      harness.respond = (_) async => jsonResponse(await reply.future);
      var handedOff = false;
      await tester.pumpWidget(
        MaterialApp(home: CsesLoginPage(onLoggedIn: () => handedOff = true)),
      );
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.text('userId'), findsNothing);
      for (final field in ['login-username', 'login-password']) {
        final input = find.byKey(ValueKey(field));
        expect(
          tester.widget<TextFormField>(input).controller!.text,
          field == 'login-username' ? 'fixture-account' : 'fixture-password',
        );
        await tester.enterText(input, '');
      }
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      await tester.pump();
      expect(find.text('请输入用户名'), findsOneWidget);
      expect(harness.requests, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('login-username')),
        'account',
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-password')),
        'password',
      );
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      expect(harness.requests, hasLength(1));
      expect(handedOff, false);
      reply.complete(success());
      await tester.pumpAndSettle();
      expect(handedOff, true);
      expect(ctx.cookieId, 'server-cookie');
      expect(User().companyId, 'server-company');
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('login-password')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'failure stays on login page; late success after dispose is ignored',
    (tester) async {
      var handedOff = false;
      final reply = Completer<Map<String, dynamic>>();
      harness.respond = (_) async => jsonResponse(await reply.future);
      await tester.pumpWidget(
        MaterialApp(home: CsesLoginPage(onLoggedIn: () => handedOff = true)),
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-username')),
        'account',
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-password')),
        'wrong',
      );
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      await tester.pump();
      reply.complete({'isSuccess': false, 'message': '密码错误'});
      await tester.pumpAndSettle();
      expect(find.text('密码错误'), findsOneWidget);
      expect(handedOff, false);
      final late = Completer<Map<String, dynamic>>();
      harness.respond = (_) async => jsonResponse(await late.future);
      await tester.pumpWidget(
        MaterialApp(
          home: CsesLoginPage(
            key: const ValueKey('new-login'),
            onLoggedIn: () => handedOff = true,
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-username')),
        'account',
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-password')),
        'password',
      );
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox());
      late.complete(success());
      await tester.pumpAndSettle();
      expect(handedOff, false);
      expect(ctx.cookieId, isNull);
      expect(User().companyId, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
