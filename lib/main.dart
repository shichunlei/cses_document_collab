import 'package:cses_common/runtime/preferences/sp_util.dart';
import 'package:cses_mobile_collab_demo/src/demo/app.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SpUtil.getInstance();
  runApp(const CsesCollabDemoApp());
}
