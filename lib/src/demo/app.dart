import 'package:cses_mobile_collab_demo/src/demo/collab_demo_page.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_login_page.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class CsesCollabDemoApp extends StatefulWidget {
  const CsesCollabDemoApp({super.key});

  @override
  createState() => _CsesCollabDemoAppState();
}

/// 持有当前内存会话；登录成功后切入文档宿主，退出时销毁宿主及其 WS。
class _CsesCollabDemoAppState extends State<CsesCollabDemoApp> {
  CsesAccountSession? _session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CSES Mobile Collab Demo',
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en')],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B5BD6),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F7FA),
        useMaterial3: true,
      ),
      home: _session == null
          ? CsesLoginPage(
              onLoggedIn: (session) => setState(() => _session = session),
            )
          : CollabDemoPage(
              session: _session,
              onLogout: () => setState(() => _session = null),
            ),
    );
  }
}
