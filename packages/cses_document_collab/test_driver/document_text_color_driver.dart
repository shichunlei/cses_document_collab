import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// 驱动颜色设备验收并保存截图；TEXT_COLOR_SCREENSHOTS可指定宿主输出目录。
Future<void> main() => integrationDriver(onScreenshot: _saveScreenshot);

/// 保存场景[name]的PNG[bytes]；[args]为截图接口可选元数据，本驱动不使用。
/// 写入失败向驱动传播，不把未保存截图计作成功；正常完成返回true。
Future<bool> _saveScreenshot(String name, List<int> bytes, [Map<String, Object?>? args]) async {
  final directory = Directory(
    Platform.environment['TEXT_COLOR_SCREENSHOTS'] ?? 'build/document-text-color-screenshots',
  );
  await directory.create(recursive: true);
  await File('${directory.path}/$name.png').writeAsBytes(bytes, flush: true);
  return true;
}
