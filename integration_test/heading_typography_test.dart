import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/heading_typography_test.dart' as typography;

/// 在Android真机用实际视口和移动选择服务验证标题字号、段落depth偏移与分散对齐。
/// 使用测试正文，不登录账号、不读写正式文档；期望数据由0.11.21发布代码生成。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    expect(Platform.isAndroid, isTrue, reason: '必须在Android设备执行');
  });
  typography.registerHeadingTypographyTests(useDeviceViewport: true);
}
