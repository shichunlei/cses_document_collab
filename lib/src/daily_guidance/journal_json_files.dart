import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'file_journal_store.dart';
import 'journal_draft.dart';
import 'journal_store.dart';

/// 系统JSON文件选择/保存与独立导入草稿端口，页面借用，不持有编辑器或认证资源。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_json_files.dart';
/// const files = DeviceJournalJsonFiles();
/// final snapshot = await files.pick();
/// if (snapshot != null) await files.save(snapshot, '文档.json');
/// ```
abstract interface class JournalJsonFiles {
  /// 读取所选UTF-8根快照，取消返回null；超限/非法内容抛FormatException，不改源文件。
  Future<Map<String, dynamic>?> pick();

  /// 将独立[snapshot]保存为[fileName]，返回是否完成；取消返回false，失败抛错。
  Future<bool> save(Map<String, dynamic> snapshot, String fileName);

  /// 在[scope]账号分区创建持有独立[draft]的存储；不覆盖当前日记，失败不返回可打开的存储。
  Future<JournalStore> createImportedStore(JournalDraft draft, String scope);
}

/// 使用系统文件对话框，编解码/读取放到后台，导入草稿单独落在应用私有目录。
final class DeviceJournalJsonFiles implements JournalJsonFiles {
  /// 创建无资源服务，平台句柄由每次调用及系统持有。
  const DeviceJournalJsonFiles();

  /// 选择单个JSON并后台校验，取消返回null，源文件不被删除或重写。
  @override
  Future<Map<String, dynamic>?> pick() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null) return null;
    if (file.path == null || !file.name.toLowerCase().endsWith('.json')) {
      throw const FormatException('请选择可读取的JSON文件');
    }
    return compute(_readSnapshot, file.path!);
  }

  /// 后台编码借用的[snapshot]后以[fileName]打开系统保存框；平台负责实际写入。
  @override
  Future<bool> save(Map<String, dynamic> snapshot, String fileName) async {
    final bytes = await compute(_encodeSnapshot, snapshot);
    final result = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: 'application/json',
    );
    return result != null;
  }

  /// 将[draft]原子保存到[scope]分区下的唯一文件；不在路径中暴露原账号信息。
  @override
  Future<JournalStore> createImportedStore(
    JournalDraft draft,
    String scope,
  ) async {
    final support = await getApplicationSupportDirectory();
    final account = sha256.convert(utf8.encode(scope)).toString();
    final store = FileJournalStore(
      directory: Directory('${support.path}/journal-imports/$account'),
      scope: 'import-${DateTime.now().microsecondsSinceEpoch}',
    );
    await store.write(draft);
    return store;
  }
}

/// 后台最多读取[path]的4MiB加一个字节，严格UTF-8解码并校验；流结束或失败均关闭文件。
Future<Map<String, dynamic>> _readSnapshot(String path) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in File(
    path,
  ).openRead(0, BlockCraftJsonCodec.byteLimit + 1)) {
    bytes.add(chunk);
  }
  if (bytes.length > BlockCraftJsonCodec.byteLimit) {
    throw const FormatException('文档JSON不能超过4MiB');
  }
  final value = jsonDecode(utf8.decode(bytes.takeBytes()));
  if (value is! Map) throw const FormatException('桌面JSON必须是根块对象');
  final result = Map<String, dynamic>.from(value);
  BlockCraftJsonCodec.validate(result);
  return result;
}

/// 后台校验并编码独立[snapshot]为两空格缩进UTF-8，不持有文件或编辑资源。
Uint8List _encodeSnapshot(Map<String, dynamic> snapshot) {
  BlockCraftJsonCodec.validate(snapshot);
  return Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(snapshot)),
  );
}
