import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real native regression gates for ownership, authorization and persisted data.
/// Run cargo build first: missing native binaries fail this extraction gate.
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
    'a rejected second controller cannot close the active native Doc',
    () async {
      final dir = await Directory.systemTemp.createTemp('collab-ownership-');
      final first = CollabController.localDraft(
        databasePath: '${dir.path}/first.sqlite',
      );
      final second = CollabController.localDraft(
        databasePath: '${dir.path}/second.sqlite',
      );
      try {
        await first.initialize();
        final ids = native.currentBlocks().map((b) => b.id).toList();
        await expectLater(
          second.initialize(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains('COLLAB_DOCUMENT_IN_USE'),
            ),
          ),
        );
        await second.close();
        expect(native.currentBlocks().map((b) => b.id), ids);
        expect(first.canEdit, isTrue);
        expect(first.header, isNull);
        expect(native.currentBlocks(), isEmpty); // 新草稿没有自有头部或默认图片。
        final state = first.editorState;
        await state.apply(
          state.transaction..insertText(state.document.first!, 0, '草稿正文'),
        );
        await first.close();
        final next = CollabController.localDraft(
          databasePath: '${dir.path}/first.sqlite',
        );
        await next.initialize();
        expect(next.persistedUpdateCount, greaterThan(0));
        await next.close();
      } finally {
        await second.close();
        await first.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'formal cache survives reopen; read-only sync withholds pending edits',
    () async {
      final dir = await Directory.systemTemp.createTemp('collab-formal-');
      final gateway = _Gateway();
      final fixture = await File(
        'rust/tests/fixtures/blockcraft-basic.update',
      ).readAsBytes();
      CollabDocumentConfig config(bool editable) => CollabDocumentConfig(
        documentId: 'fixture-doc',
        serverIdentity: 'wss://test.example/ws',
        companyId: 'company',
        userId: 'user',
        userName: '测试用户',
        databasePath: '${dir.path}/updates.sqlite',
        editable: editable,
      );
      final metadata = _Metadata()..pending = Completer<DocumentMetadata>();
      final first = CollabController.cses(
        config: config(true),
        gateway: gateway,
        services: CollabHostServices(documentMetadata: metadata),
      );
      CollabController? reopened;
      try {
        await first.initialize();
        gateway.sync(fixture);
        await Future<void>.delayed(Duration.zero);
        expect(first.status, ConnectionStatus.online);
        expect(first.editorState.document.root.children.length, 3);
        expect(first.header!.loading, isTrue);
        expect(first.canEdit, isTrue); // 业务头部未返回时，正文仍可加载和编辑。
        metadata.pending!.complete(
          DocumentMetadata(
            id: 'fixture-doc',
            name: '正式业务标题',
            canRename: true,
            canChangeAppearance: true,
          ),
        );
        await first.header!.refresh();
        expect(first.header!.value!.name, '正式业务标题');
        final vector = native.encodeStateVector();
        final outbound = gateway.lastUpdate;
        expect(
          await first.header!.save(
            const DocumentMetadataPatch.rename('手机业务标题'),
          ),
          isTrue,
        );
        expect(first.header!.value!.name, '手机业务标题');
        expect(native.encodeDocumentDiff(stateVector: vector), [0, 0]);
        expect(gateway.lastUpdate, outbound);
        expect(first.editorState.undoManager.undoStack, isEmpty);
        await first.setEditable(false);
        expect(
          await first.header!.save(const DocumentMetadataPatch.icon(null)),
          isFalse,
        );
        await first.setEditable(true);
        gateway.sync(fixture);
        await Future<void>.delayed(Duration.zero);
        // The editor view enables its borrowed EditorState after the formal
        // root arrives. This native transaction test models that input boundary.
        expect(first.canEdit, isTrue);
        first.editorState.editable = first.canEdit;
        final node = first.editorState.document.root.children.first;
        final transaction = first.editorState.transaction
          ..insertText(node, 0, '手机-');
        await first.editorState.apply(
          transaction,
          options: const ApplyOptions(recordUndo: false),
        );
        await Future<void>.delayed(Duration.zero);
        expect(native.currentBlocks().first.text, '手机-正文😀');
        await first.close();

        reopened = CollabController.cses(
          config: config(false),
          gateway: gateway,
        );
        await reopened.initialize();
        expect(reopened.persistedUpdateCount, greaterThan(0));
        expect(reopened.editorState.editable, isFalse);
        gateway.sync(fixture);
        await Future<void>.delayed(Duration.zero);
        expect(base64Decode(gateway.lastUpdate), [0, 0]);
        expect(native.currentBlocks().first.text, '手机-正文😀');
        await reopened.setEditable(true);
        gateway.sync(fixture);
        expect(base64Decode(gateway.lastUpdate).length, greaterThan(2));
        await Future.wait([
          reopened.setEditable(false),
          reopened.setEditable(true),
          reopened.setEditable(false),
        ]);
        gateway.sync(fixture);
        expect(reopened.canEdit, isFalse);
        expect(base64Decode(gateway.lastUpdate), [0, 0]);
        await reopened.close();
        expect(gateway.events.isClosed, isFalse);
        expect(gateway.activePages, isEmpty);
      } finally {
        await reopened?.close();
        await first.close();
        await gateway.events.close();
        await dir.delete(recursive: true);
      }
    },
  );
}

/// Borrowed transport with exact callbacks; deliberately has no socket close API.
class _Gateway implements CsesCollabGateway {
  final events = StreamController<bool>.broadcast();
  final activePages = <String>{};
  Map<String, void Function(Map<String, dynamic>)> callbacks = {};
  String lastUpdate = '';
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionStates => events.stream;
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    activePages.add(pageId);
    this.callbacks = callbacks;
  }

  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (action == 'collabUpdate') lastUpdate = body['data'] as String;
    return true;
  }

  @override
  Future<void> unregister(String pageId) async => activePages.remove(pageId);
  void sync(List<int> fixture) => callbacks['collabSync']!({
    'data': base64Encode(fixture),
    'stateVector': base64Encode([0]),
  });
}

/// 借用的业务端口不接触原生正文；用真实控制器验证生命周期与只读门禁。
class _Metadata implements DocumentMetadataService {
  /// 可控的未完成读取；null使用固定成功快照。
  Completer<DocumentMetadata>? pending;

  /// 为 [documentId] 返回固定快照或等待测试Completer，不读取原生正文。
  @override
  Future<DocumentMetadata> load(String documentId) async => pending == null
      ? DocumentMetadata(
          id: documentId,
          name: '正式业务标题',
          canRename: true,
          canChangeAppearance: true,
          icon: {'type': 'emoji', 'value': '😘'},
        )
      : await pending!.future;

  /// 对测试文档 [documentId] 的 [patch] 立即确认成功，不写入原生正文。
  @override
  Future<void> update(String documentId, DocumentMetadataPatch patch) async {}
}
