import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/mobile_selection_menu_test.dart' as selection_menu;

/// 在真实移动选择服务上运行划词触摸回归，不使用账号、网络或原生协同文档。
/// 从 Demo 宿主用本包 test_driver 运行，保留安装应用与已有本地数据。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android selection menu, link and inline formula gestures', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue, reason: '需要真实 Android 选择服务');
    await selection_menu.verifyMobileSelectionMenuGestures(tester);
  });
}
