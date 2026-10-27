import 'dart:convert';
import 'dart:io';

import 'journal_draft.dart';
import 'journal_store.dart';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 单个账号的本机日记文件，使用后台编解码、flush和同目录rename提交完整快照。
///
/// ```dart
/// import 'dart:io';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/file_journal_store.dart';
/// final store = FileJournalStore(directory: Directory('/app/journals'), scope: 'account-hash');
/// // 同一scope仅由一个LocalJournalPage串行访问。
/// ```
final class FileJournalStore implements JournalStore {
  /// [directory]为应用私有目录，[scope]是账号分区哈希，仅允许字母、数字和短横线。
  FileJournalStore({required Directory directory, required String scope})
    : _directory = directory {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,128}$').hasMatch(scope)) {
      throw ArgumentError.value(scope, 'scope');
    }
    _file = File(p.join(directory.path, '$scope.json'));
  }

  final Directory _directory;
  late final File _file;

  /// 单写入者会话只检查一次旧协议，避免每次自动保存重复读取完整文件。
  bool _checkedLegacyBackup = false;

  /// 异步读取当前账号草稿，在后台校验；无文件返回null，损坏或超4MiB时抛错且保留原文件。
  @override
  Future<JournalDraft?> read() async {
    if (!await _file.exists()) return null;
    if (await _file.length() > 4 * 1024 * 1024) {
      throw const FormatException('日记文件超过允许大小');
    }
    return compute(_decodeDraft, await _file.readAsString());
  }

  /// 在后台编码独立[draft]后原子替换；调用方保证同一文件只有一个串行写入者。
  /// Future完成表示文件flush及rename成功；失败不会把临时文件当作正式草稿读取。
  /// 首次覆盖v1前通过临时文件flush/rename提交原字节备份，备份失败拒绝升级。
  /// 已有备份不匹配时保留它并另存带内容哈希的备份，不信任不完整文件。
  @override
  Future<void> write(JournalDraft draft) async {
    final encoded = await compute(_encodeDraft, draft);
    if (utf8.encode(encoded).length > 4 * 1024 * 1024) {
      throw const FormatException('日记文件超过允许大小');
    }
    await _directory.create(recursive: true);
    // 首次v1升级保留原始字节；失败仍保留正式文件，不以恢复对象重编码替代原证据。
    if (!_checkedLegacyBackup && await _file.exists()) {
      final original = await _file.readAsString();
      if (await compute(_isLegacyDraft, original)) {
        var backup = File('${_file.path}.v1.bak');
        if (await backup.exists() && await backup.readAsString() != original) {
          // 保留既有备份；部分写入或其他旧快照不能被当作本次升级的完整恢复依据。
          final fingerprint = await compute(_draftFingerprint, original);
          backup = File('${_file.path}.v1.$fingerprint.bak');
        }
        if (!await backup.exists() || await backup.readAsString() != original) {
          final pendingBackup = File('${backup.path}.tmp');
          await pendingBackup.writeAsString(original, flush: true);
          await pendingBackup.rename(backup.path);
        }
      }
    }
    _checkedLegacyBackup = true;
    final temporary = File('${_file.path}.tmp');
    await temporary.writeAsString(encoded, flush: true);
    await temporary.rename(_file.path);
  }
}

/// 后台解析并校验文件[value]；未知版本和损坏正文不降级为空日记。
JournalDraft _decodeDraft(String value) {
  final json = jsonDecode(value);
  if (json is! Map<String, dynamic>) throw const FormatException('日记文件格式无效');
  return JournalDraft.fromJson(json);
}

/// 后台编码独立[draft]，不访问编辑器或页面状态。
String _encodeDraft(JournalDraft draft) => jsonEncode(draft.toJson());

/// 后台识别原始文件[value]是否为v1，解析失败向调用方抛出，不覆盖未知字节。
bool _isLegacyDraft(String value) {
  final json = jsonDecode(value);
  return json is Map && json['schemaVersion'] == 1;
}

/// 在后台计算原文件[value]的稳定指纹，用于保留不同内容的旧协议备份。
String _draftFingerprint(String value) =>
    sha256.convert(utf8.encode(value)).toString();
