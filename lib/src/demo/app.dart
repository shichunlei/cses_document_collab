import 'package:bot_toast/bot_toast.dart';
import 'package:cses_mobile_collab_demo/src/demo/collab_demo_page.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// 提供登录与文档页面，以及 Common 提示和加载浮层所需的全局宿主。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/app.dart';
/// import 'package:flutter/widgets.dart';
///
/// void main() => runApp(const CsesCollabDemoApp());
/// ```
class CsesCollabDemoApp extends StatefulWidget {
  /// 创建应用；[key] 控制组件身份与状态复用。
  const CsesCollabDemoApp({super.key});

  /// 创建持有登录状态的应用状态。
  @override
  createState() => _CsesCollabDemoAppState();
}

/// 管理登录页和文档页切换；账号上下文由 Common 持有。
class _CsesCollabDemoAppState extends State<CsesCollabDemoApp> {
  bool _loggedIn = false;

  /// 为 [context] 构建应用，并在导航树外挂载 Toast 浮层以跨页面显示提示。
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      builder: BotToastInit(),
      navigatorObservers: [BotToastNavigatorObserver()],
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
