import 'package:cses_mobile_collab_demo/src/app.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/rust/frb_generated.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerCsesRichTextAttributes();
  await RustLib.init();
  runApp(const CsesCollabDemoApp());
}
