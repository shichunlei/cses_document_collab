import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

/// 保存隔离表情用例的性能JSON与PNG；输出目录由COLLAB_EMOJI_DEVICE_OUTPUT_DIR指定。
/// 无该环境变量时写入build/emoji-device；失败时也保留已有指标，不读取业务数据。
Future<void> main() => integrationDriver(
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    if (data == null) return;
    final output = Directory(
      Platform.environment['COLLAB_EMOJI_DEVICE_OUTPUT_DIR'] ??
          'build/emoji-device',
    );
    await output.create(recursive: true);
    final report = Map<String, dynamic>.from(data);
    final screenshots = report.remove('screenshots') as List<dynamic>? ?? [];
    for (final screenshot in screenshots) {
      final entry = screenshot as Map<String, dynamic>;
      final name = entry['screenshotName'] as String;
      if (!RegExp(r'^[a-z0-9-]+$').hasMatch(name)) {
        throw FormatException('Invalid screenshot name');
      }
      await File(
        '${output.path}/$name.png',
      ).writeAsBytes((entry['bytes'] as List<dynamic>).cast<int>());
    }
    await File(
      '${output.path}/performance.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  },
);
