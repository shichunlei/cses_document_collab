import 'package:cses_common/runtime/preferences/sp_util.dart';
import 'package:cses_mobile_collab_demo/src/demo/app.dart';
import 'package:cses_mobile_collab_demo/src/demo/demo_environment.dart';
import 'package:flutter/material.dart';

/// 初始化资源与偏好，在读取本地环境配置后创建登录页；配置损坏时显示安全错误。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await DemoEnvironment.load();
  } on FormatException catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(body: Center(child: Text(error.message))),
      ),
    );
    return;
  }
  await SpUtil.getInstance();
  runApp(const CsesCollabDemoApp());
}
