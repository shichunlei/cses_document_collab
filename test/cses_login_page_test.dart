import 'dart:async';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'username/password only; validation, single submission and successful handoff',
    (tester) async {
      final reply = Completer<Map<String, dynamic>>();
      var calls = 0;
      CsesAccountSession? session;
      await tester.pumpWidget(
        MaterialApp(
          home: CsesLoginPage(
            onLoggedIn: (value) => session = value,
            login: CsesAccountLogin(
              deviceIdProvider: () async => 'device',
              request: (_, _) {
                calls++;
                return reply.future;
              },
            ),
          ),
        ),
      );
      expect(find.byType(TextFormField), findsNWidgets(2));
      expect(find.text('userId'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      await tester.pump();
      expect(find.text('请输入用户名'), findsOneWidget);
      expect(calls, 0);
      await tester.enterText(
        find.byKey(const ValueKey('login-username')),
        'account',
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-password')),
        'password',
      );
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('login-submit')));
      expect(calls, 1);
      expect(session, isNull);
      reply.complete({
        'isSuccess': true,
        'cookieId': 'cookie',
        'userId': 'user',
        'companyId': 'company',
      });
      await tester.pumpAndSettle();
      expect(session!.settings.documentId, csesDemoDocumentId);
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
      await tester.pumpWidget(
        MaterialApp(
          home: CsesLoginPage(
            onLoggedIn: (_) => handedOff = true,
            login: CsesAccountLogin(
              deviceIdProvider: () async => 'device',
              request: (_, _) => reply.future,
            ),
          ),
        ),
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
      await tester.pumpWidget(
        MaterialApp(
          home: CsesLoginPage(
            key: const ValueKey('new-login'),
            onLoggedIn: (_) => handedOff = true,
            login: CsesAccountLogin(
              deviceIdProvider: () async => 'device',
              request: (_, _) => late.future,
            ),
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
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      late.complete({
        'isSuccess': true,
        'cookieId': 'cookie',
        'userId': 'user',
        'companyId': 'company',
      });
      await tester.pumpAndSettle();
      expect(handedOff, false);
      expect(tester.takeException(), isNull);
    },
  );
}
