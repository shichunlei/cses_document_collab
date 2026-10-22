import 'dart:io';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 使用真实FRB与SQLite验证公开初始化端口；互通模式另运行真实桌面Yjs进程。
void main() {
  const desktop = String.fromEnvironment('BOOTSTRAP_DESKTOP_ROOT');
  const packageRoot = String.fromEnvironment('BOOTSTRAP_PACKAGE_ROOT');
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(p.join('rust', 'target', 'debug', 'libcses_collab_core.$suffix')).absolute.path,
      ),
    );
  });
  test('prepare reuses CRDT and opens editable with an empty initial undo stack', () async {
    final dir = await Directory.systemTemp.createTemp('document-bootstrap-');
    final config = _config(dir);
    try {
      final first = await _prepare(config);
      final repeated = await _prepare(config);
      expect(repeated.snapshotJson, first.snapshotJson);
      expect(first.insertDiffs.length, 2);
      expect(first.insertDiffs[1]['content'], isEmpty);
      final changed = first.insertDiffs;
      changed[0]['props']['foreign'] = 'mutation';
      expect(first.insertDiffs[0]['props'], isEmpty);
      final controller = CollabController.cses(config: config, gateway: _OfflineGateway());
      try {
        await controller.initialize();
        expect(controller.canEdit, isTrue);
        expect(controller.persistedUpdateCount, 1);
        expect(controller.editorState.undoManager.undoStack.isEmpty, isTrue);
        final node = controller.editorState.document.first!;
        await controller.editorState.apply(controller.editorState.transaction..insertText(node, 0, '手机新文档'));
        expect(native.currentBlocks().single.text, '手机新文档');
      } finally {
        await controller.close();
      }
      await expectLater(_prepare(config), throwsA(anything));
      final reopened = CollabController.cses(config: config, gateway: _OfflineGateway());
      try {
        await reopened.initialize();
        expect(native.currentBlocks().single.text, '手机新文档');
      } finally {
        await reopened.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('preparation cannot replace another active controller', () async {
    final dir = await Directory.systemTemp.createTemp('bootstrap-owner-');
    final owner = CollabController.localDraft(databasePath: p.join(dir.path, 'owner.sqlite'));
    try {
      await owner.initialize();
      await expectLater(_prepare(_config(dir)), throwsA(isA<StateError>()));
      expect(owner.canEdit, isTrue);
    } finally {
      await owner.close();
      await dir.delete(recursive: true);
    }
  });
  test(
    'published desktop Yjs reads mobile root and returns an editable update',
    () async {
      final dir = await Directory.systemTemp.createTemp('bootstrap-interop-');
      final config = _config(dir);
      try {
        final prepared = await _prepare(config);
        native.openCsesDocument(
          documentId: config.documentId,
          cacheDocumentId: config.cacheDocumentId,
          databasePath: config.databasePath,
        );
        final initial = native.encodeDocumentDiff(stateVector: [0]);
        await File(p.join(dir.path, 'phone.update')).writeAsBytes(initial, flush: true);
        await File(p.join(dir.path, 'snapshot.json')).writeAsString(prepared.snapshotJson);
        const node = String.fromEnvironment('BOOTSTRAP_NODE_EXECUTABLE', defaultValue: 'node');
        final result = await Process.run(node, ['tool/verify_document_bootstrap.mjs', desktop, packageRoot, dir.path]);
        expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
        native.applyDocumentUpdate(bytes: await File(p.join(dir.path, 'desktop.update')).readAsBytes());
        expect(native.currentBlocks().single.id, 'initial-paragraph');
        expect(native.currentBlocks().single.text, '桌面接续手机新建');
        native.closeDocument();
        native.openCsesDocument(
          documentId: config.documentId,
          cacheDocumentId: config.cacheDocumentId,
          databasePath: config.databasePath,
        );
        expect(native.currentBlocks().single.text, '桌面接续手机新建');
        native.closeDocument();
      } finally {
        native.closeDocument();
        await dir.delete(recursive: true);
      }
    },
    skip: desktop.isEmpty || packageRoot.isEmpty ? '桌面互通需显式提供BOOTSTRAP_DESKTOP_ROOT及BOOTSTRAP_PACKAGE_ROOT' : false,
  );
}

/// 使用[dir]内独立SQLite配置正式根，账号字段用于真实缓存隔离。
CollabDocumentConfig _config(Directory dir) => CollabDocumentConfig(
  documentId: 'phone-new-document',
  serverIdentity: 'wss://example.test/ws',
  companyId: 'company',
  userId: 'phone',
  databasePath: p.join(dir.path, 'updates.sqlite'),
  editable: true,
);

/// 用固定初始化参数准备[config]，验证恢复不重新分配段落身份。
Future<PreparedDocument> _prepare(CollabDocumentConfig config) => DocumentBootstrapper.prepareBlank(
  config: config,
  operationId: 'operation',
  paragraphId: 'initial-paragraph',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1792584000000),
);

/// 无网络端口；只验证本地初始化和编辑路径，不宣称线上保存。
class _OfflineGateway implements CsesCollabGateway {
  /// 主连接离线，不产生发送。
  @override
  bool get isConnected => false;

  /// 不提供连接事件，session负责取消自己的订阅。
  @override
  Stream<bool> get connectionStates => const Stream.empty();

  /// 接受[pageId]/[documentId]/[instanceId]及[callbacks]本地注册，不操作正文。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {}

  /// [pageId]/[action]/[body]离线发送统一拒绝。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) => false;

  /// 解除[pageId]无资源注册。
  @override
  Future<void> unregister(String pageId) async {}
}
