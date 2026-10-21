import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/document_editor_text_color_test.dart' as colors;

/// 在Android实际视口验证协同正文黑色缺省值、局部色、链接色及容器继承。
/// 正文仅存在内存中，不登录、不连接网络或打开协同数据库；每组通过后保存设备截图。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    expect(Platform.isAndroid, isTrue, reason: '必须使用Android设备执行颜色验收');
  });
  colors.registerDocumentEditorTextColorTests(
    useDeviceViewport: true,
    onVerified: (tester, name) async {
      // 截图表面由测试框架在每组tearDown还原，下一组须重新转换。
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot(name);
    },
  );
}
