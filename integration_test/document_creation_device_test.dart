import 'dart:convert';
import 'dart:io';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_api.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_coordinator.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_page.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_store.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 隔离业务传输、使用真实平台FRB/SQLite和生产创建页验证新建到编辑及重开。
/// 不登录账号，不访问服务端，不宣称HTTP或在线协同验收通过。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('create through mobile page, edit and restore the same formal document', (
    tester,
  ) async {
    final support = await getApplicationSupportDirectory();
    final base = await Directory(
      p.join(support.path, 'creation-device-validation'),
    ).create(recursive: true);
    final dir = await base.createTemp('run-');
    final api = _DeviceApi();
    CollabController? controller;
    final config = CollabDocumentConfig(
      documentId: 'device-new-document',
      serverIdentity: 'wss://isolated.invalid/ws',
      companyId: 'isolated-company',
      userId: 'isolated-user',
      databasePath: p.join(dir.path, 'updates.sqlite'),
      editable: true,
    );
    final store = FileDocumentCreationStore(directory: dir, scope: 'device-operation');
    var ids = 0;
    final coordinator = DocumentCreationCoordinator(
      api: api,
      store: store,
      createId: () => 'device-id-${ids++}',
      closeDocument: () async {
        await controller?.close();
        controller = null;
      },
      prepare: (operation) => DocumentBootstrapper.prepareBlank(
        config: config,
        operationId: operation.operationId,
        paragraphId: operation.paragraphId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(operation.createdAt),
      ),
      openDocument: (id) async {
        expect(id, config.documentId);
        controller = CollabController.cses(config: config, gateway: _DeviceGateway());
        await controller!.initialize();
      },
    );
    try {
      await coordinator.restore();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () async {
                    final id = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => DocumentCreationPage(
                          loadDocuments: _emptyDocuments,
                          coordinator: coordinator,
                          loadTargets: api.loadTargets,
                        ),
                      ),
                    );
                    if (!context.mounted || id == null) return;
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => CollaborativeEditorPage(collab: controller!),
                      ),
                    );
                  },
                  child: const Text('开始新建'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('开始新建'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('create-blank-document')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('collaborative-appflowy-editor')), findsOneWidget);
      expect(api.creates, 1);
      expect(api.writes, 1);
      expect(controller!.canEdit, isTrue);
      final editor = controller!.editorState;
      expect(editor.undoManager.undoStack.isEmpty, isTrue);
      await editor.apply(editor.transaction..insertText(editor.document.first!, 0, '设备端新建与恢复'));
      await tester.pumpAndSettle();
      expect(editor.document.first!.delta!.toPlainText(), '设备端新建与恢复');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await coordinator.close();
      await controller!.close();
      controller = null;
      final stored = await store.read();
      expect(stored!.stage, DocumentCreationStage.completed);
      controller = CollabController.cses(config: config, gateway: _DeviceGateway());
      await controller!.initialize();
      expect(controller!.editorState.document.first!.delta!.toPlainText(), '设备端新建与恢复');
      expect(jsonDecode(stored.snapshotJson!)['children'][0]['id'], 'device-id-1');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await coordinator.close();
      await controller?.close();
      await dir.delete(recursive: true);
    }
  });
}

/// 只替换业务HTTP，不替换原生初始化、SQLite、控制器或编辑器。
class _DeviceApi implements DocumentCreationApi {
  /// 隔离建档调用次数，不代表真实服务器创建数量。
  int creates = 0;

  /// 隔离快照提交次数，不代表服务器ACK。
  int writes = 0;

  /// 隔离账号无需真实登录，不访问Common全局上下文。
  @override
  void checkSession() {}

  /// 返回测试隔离空间，避免真实业务资源写入。
  @override
  Future<List<DocumentCreationTarget>> loadTargets() async => [
    const DocumentCreationTarget(id: 'isolated-space', name: '隔离验证空间'),
  ];

  /// 核对[target]为隔离空间。
  @override
  Future<void> verifyTarget(DocumentCreationTarget target) async {
    expect(target.id, 'isolated-space');
  }

  /// 为[target]返回隔离根，不向服务端建档。
  @override
  Future<String> createBlank(DocumentCreationTarget target) async {
    creates++;
    return 'device-new-document';
  }

  /// 检查[prepared]是两个同源块，不发HTTP。
  @override
  Future<void> writeInitial(PreparedDocument prepared) async {
    writes++;
    expect(prepared.insertDiffs.length, 2);
    expect(prepared.documentId, 'device-new-document');
  }

  /// 回读[prepared]不应被成功路径调用。
  @override
  Future<InitialSnapshotState> readInitial(PreparedDocument prepared) async =>
      throw StateError('unexpected read');
}

/// 真实控制器借用的离线网关，不连接任何物理Socket。
class _DeviceGateway implements CsesCollabGateway {
  /// 整个隔离验证保持离线。
  @override
  bool get isConnected => false;

  /// 空连接事件流由session订阅及释放。
  @override
  Stream<bool> get connectionStates => const Stream.empty();

  /// 登记[pageId]/[documentId]/[instanceId]和[callbacks]的空资源边界。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {}

  /// 拒绝[pageId]/[action]/[body]离线发送。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) => false;

  /// 释放[pageId]空注册，不影响宿主或其他文档。
  @override
  Future<void> unregister(String pageId) async {}
}

/// 为[target]的第[pageNumber]页提供隔离空列表，不伪造正式文档。
Future<DocumentListPage> _emptyDocuments(DocumentCreationTarget target, int pageNumber) async =>
    DocumentListPage(items: [], totalCount: 0, pageNumber: pageNumber, pageSize: 20);
