import 'package:cses_mobile_collab_demo/src/demo/collab_demo_page.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class CsesCollabDemoApp extends StatefulWidget {
  const CsesCollabDemoApp({super.key});

  @override
  createState() => _CsesCollabDemoAppState();
}

/// 管理登录页和文档页切换；账号上下文由 Common 持有。
class _CsesCollabDemoAppState extends State<CsesCollabDemoApp> {
  bool _loggedIn = false;

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
      home: !_loggedIn
          ? CsesLoginPage(onLoggedIn: () => setState(() => _loggedIn = true))
          : CollabDemoPage(onLogout: () => setState(() => _loggedIn = false)),
    );
  }
}
