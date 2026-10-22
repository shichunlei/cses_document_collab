import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'document_creation_operation.dart';

/// 创建记录持久化端口，由宿主拥有，协调器借用。
///
/// ```dart
/// import 'dart:io';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_store.dart';
/// Future<void> readPending() async {
///   final store = FileDocumentCreationStore(directory: Directory('/host/creation'), scope: 'account-hash');
///   final operation = await store.read();
///   print(operation?.documentId);
/// }
/// ```
abstract interface class DocumentCreationStore {
  /// 读取当前账号记录；无记录返回null，损坏记录抛错，不能静默重建。
  Future<DocumentCreationOperation?> read();

  /// 持久化[operation]；完成前协调器不得执行依赖该阶段的外部写入。
  Future<void> write(DocumentCreationOperation operation);
}

/// 用临时文件、flush及同目录rename保存账号分区，不持有持续打开的文件句柄。
/// 同一scope由宿主唯一协调器串行写入，不支持多个写入者并发替换记录。
///
/// ```dart
/// import 'dart:io';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_store.dart';
/// Future<void> readPending() async {
///   final store = FileDocumentCreationStore(directory: Directory('/host/creation'), scope: 'sha256-account');
///   final pending = await store.read();
///   print(pending?.stage);
/// }
/// ```
final class FileDocumentCreationStore implements DocumentCreationStore {
  /// [directory]由宿主选择，[scope]为不含凭证的账号哈希，只允许字母数字和短横线。
  FileDocumentCreationStore({required Directory directory, required String scope}) : _directory = directory {
    if (!RegExp(r'^[a-zA-Z0-9-]{1,128}$').hasMatch(scope)) throw const FormatException('创建记录分区无效');
    _file = File(p.join(directory.path, '$scope.json'));
  }
  final Directory _directory;
  late final File _file;

  /// 读取当前分区；不忽略JSON错误或不完整阶段。
  @override
  Future<DocumentCreationOperation?> read() async {
    if (!await _file.exists()) return null;
    if (await _file.length() > 65536) throw const FormatException('创建恢复记录超过允许大小');
    final value = jsonDecode(await _file.readAsString());
    if (value is! Map<String, dynamic>) throw const FormatException('创建恢复记录损坏');
    return DocumentCreationOperation.fromJson(value);
  }

  /// 原子替换[operation]；写入失败保留此前记录，临时文件不作为恢复依据。
  @override
  Future<void> write(DocumentCreationOperation operation) async {
    await _directory.create(recursive: true);
    final temporary = File(p.setExtension(_file.path, '.json.tmp'));
    await temporary.writeAsString(jsonEncode(operation.toJson()), flush: true);
    await temporary.rename(_file.path);
  }
}
