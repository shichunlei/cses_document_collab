import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用真实 FRB、控制器与 SQLite 验证表格编辑、权限和恢复；缺库直接失败。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('rust/target/debug/libcses_collab_core.$suffix').absolute.path,
      ),
    );
  });
  test(
    'formal table body edits cross controller/FRB, undo/redo and reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp('table-frb-');
      final config = CollabDocumentConfig(
        documentId: 'fixture-doc',
        serverIdentity: 'wss://table.test/ws',
        companyId: 'company',
        userId: 'user',
        userName: '测试',
        editable: true,
        databasePath: '${directory.path}/table.sqlite',
      );
      native.openCsesDocument(
        documentId: config.documentId,
        cacheDocumentId: config.cacheDocumentId,
        databasePath: config.databasePath,
      );
      native.applyDocumentUpdate(
        bytes: await File(
          'rust/tests/fixtures/blockcraft-table.update',
        ).readAsBytes(),
      );
      native.closeDocument();
      var controller = CollabController.cses(
        config: config,
        gateway: _OfflineGateway(),
      );
      try {
        await controller.initialize();
        expect(controller.canEdit, isTrue);
        final state = controller.editorState;
        final body = state.document.nodeAtPath([3, 0, 0, 0])!;
        final source = body.delta!.toPlainText();
        await state.apply(state.transaction..insertText(body, 0, '手机'));
        expect(controller.error, isNull);
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'body-0-0').text,
          '手机$source',
        );
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'body-0-0').text,
          source,
        );
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'body-0-0').text,
          '手机$source',
        );
        await _editTable(
          state,
          CollabTableAction.merge,
          endRow: 1,
          endColumn: 1,
        );
        expect(controller.error, isNull);
        expect(native.documentReadOnlyReason(), isNull);
        expect(
          collabTableSpan(
            findCollabTable(state, 'table-1')!.children.first.children.first,
            'rowspan',
          ),
          2,
        );
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(
          collabTableRegions(findCollabTable(state, 'table-1')!).length,
          6,
        );
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(controller.error, isNull);
        await _editTable(state, CollabTableAction.insertRow, row: 1);
        expect(findCollabTable(state, 'table-1')!.children.length, 3);
        await _editTable(state, CollabTableAction.deleteColumn);
        expect(
          findCollabTable(state, 'table-1')!.children.first.children.length,
          2,
        );
        await _editTable(
          state,
          CollabTableAction.resizeColumn,
          column: 1,
          width: 240,
        );
        expect(
          collabTableLayout(findCollabTable(state, 'table-1'))['colWidths'],
          [160, 240],
        );
        await _editTable(state, CollabTableAction.deleteRow);
        await _editTable(state, CollabTableAction.split);
        expect(controller.error, isNull);
        expect(native.documentReadOnlyReason(), isNull);
        final restored = native.currentBlocks().firstWhere(
          (b) => b.id == 'body-0-0',
        );
        expect(restored.text, '手机$source');
        final inserted = await insertCollabTable(
          state,
          Selection.single(path: [0], startOffset: 0),
          rows: 2,
          columns: 2,
        );
        expect(
          inserted,
          isNotNull,
          reason: state.document.root.children
              .map(
                (n) =>
                    '${n.type}:${collabTableNodeId(n)}:${n.delta?.toPlainText()}',
              )
              .join('|'),
        );
        expect(
          native.currentBlocks().where((b) => b.blockType == 'table').length,
          2,
        );
        expect(
          state.undoManager.canUndo,
          isTrue,
          reason: 'history empty after creation: ${controller.error}',
        );
        expect(state.undoManager.externalHistory, isNotNull);
        expect(state.undoManager.undoStack.isEmpty, isTrue);
        state.undoManager.undo();
        await controller.undo();
        expect(controller.error, isNull);
        expect(
          native.currentBlocks().where((b) => b.blockType == 'table').length,
          1,
        );
        state.undoManager.redo();
        await controller.redo();
        expect(controller.error, isNull);
        expect(
          native.currentBlocks().where((b) => b.blockType == 'table').length,
          2,
        );
        await controller.setEditable(false);
        final currentBody = findCollabTable(
          state,
          'table-1',
        )!.children.first.children.first.children.first;
        await state.apply(state.transaction..insertText(currentBody, 0, '禁止'));
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'body-0-0').text,
          '手机$source',
        );
        await controller.close();
        controller = CollabController.cses(
          config: config,
          gateway: _OfflineGateway(),
        );
        await controller.initialize();
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'body-0-0').text,
          '手机$source',
        );
        expect(
          findCollabTable(controller.editorState, 'table-1')!.children.length,
          2,
        );
        expect(
          collabTableLayout(
            findCollabTable(controller.editorState, 'table-1'),
          )['colWidths'],
          [160, 240],
        );
      } finally {
        await controller.close();
        await directory.delete(recursive: true);
      }
    },
  );
}

/// 在借用[state]中按最新表指纹执行[action]；[row]/[column]定位，[endRow]/[endColumn]为合并范围，[width]为列宽。
Future<void> _editTable(
  EditorState state,
  CollabTableAction action, {
  int row = 0,
  int column = 0,
  int? endRow,
  int? endColumn,
  double? width,
}) async {
  final table = findCollabTable(state, 'table-1')!;
  expect(
    await applyCollabTableEdit(
      state,
      'table-1',
      collabTableFingerprint(table),
      action,
      row: row,
      column: column,
      endRow: endRow,
      endColumn: endColumn,
      width: width,
    ),
    isTrue,
  );
  await Future<void>.delayed(Duration.zero);
}

/// 无物理资源的借用离线传输；本用例只验证本地权威与桥接，不宣称服务端 ACK。
class _OfflineGateway implements CsesCollabGateway {
  /// 始终离线，禁止初始化期间发送握手。
  @override
  bool get isConnected => false;

  /// 无连接变化或订阅资源。
  @override
  Stream<bool> get connectionStates => const Stream.empty();

  /// 接受 [pageId]、[documentId]、[instanceId] 及 [callbacks]，不保留回调或开启连接。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {}

  /// [pageId] 的 [action] 和 [body] 不会发送；返回 false 表示离线。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) => false;

  /// 释放 [pageId] 的注册；没有持有资源，重复调用安全。
  @override
  Future<void> unregister(String pageId) async {}
}
