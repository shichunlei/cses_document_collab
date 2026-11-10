import 'dart:convert';
import 'dart:io';

import 'package:cses_mobile_collab_demo/src/demo/demo_environment.dart';
import 'package:flutter/services.dart';

/// 提供内存 JSON 资源，测试不会读取本机 `.env.json` 的真实配置。
///
/// ```dart
/// final bundle = TestEnvironmentBundle('{}');
/// await DemoEnvironment.load(bundle: bundle);
/// ```
class TestEnvironmentBundle extends CachingAssetBundle {
  /// [json] 是用于 `.env.json` 的合成内容；[missing] 模拟资源缺失，默认 false。
  TestEnvironmentBundle(this.json, {this.missing = false});

  /// 仅供测试的 JSON 内容，不包含真实凭证。
  final String json;

  /// 是否模拟资源不存在，由测试持有。
  final bool missing;

  /// 对 [key] 返回 JSON 的 UTF-8 字节；资源缺失时抛出 StateError。
  @override
  Future<ByteData> load(String key) async {
    if (missing || key != '.env.json') throw StateError('missing test asset');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(json)));
  }
}

/// 从测试专用文件读取合成配置；完成后登录服务与页面可同步使用配置快照。
Future<void> loadTestEnvironment() async {
  final json = await File('config/test.env.json').readAsString();
  await DemoEnvironment.load(bundle: TestEnvironmentBundle(json));
}
