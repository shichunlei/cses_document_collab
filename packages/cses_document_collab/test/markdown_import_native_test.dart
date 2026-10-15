import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/markdown_import.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证导入内容经过原生投影与 SQLite 重开后仍保留。
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
  test('Markdown transaction survives native projection and reopen', () async {
    final directory = await Directory.systemTemp.createTemp('markdown-import-');
    final path = '${directory.path}/updates.sqlite';
    final config = CollabDocumentConfig(
      documentId: 'fixture-doc',
      serverIdentity: 'test',
      companyId: 'company',
      userId: 'user',
      databasePath: path,
      editable: true,
    );
    native.openCsesDocument(
      documentId: config.documentId,
      cacheDocumentId: config.cacheDocumentId,
      databasePath: path,
    );
    native.applyDocumentUpdate(
      bytes: await File(
        'rust/tests/fixtures/blockcraft-basic.update',
      ).readAsBytes(),
    );
    native.closeDocument();
    var controller = CollabController.cses(
      config: config,
      gateway: const _OfflineGateway(),
    );
    try {
      await controller.initialize();
      final state = controller.editorState;
      await state.apply(
        state.transaction..insertText(state.document.first!, 0, '原正文'),
      );
      final originalCount = native.currentBlocks().length;
      final nodes = decodeMarkdownImport(
        '# 导入标题\n\n3. 第三项\n4. 第四项\n\n```dart\nprint(1);\n```\n\n---\n\n![图片](https://example.com/a.png)',
      ).map((value) => Node.fromJson(Map<String, Object>.from(value))).toList();
      await state.apply(
        state.transaction
          ..insertNodes([state.document.root.children.length], nodes),
      );
      final all = native.currentBlocks();
      final imported = all.sublist(originalCount);
      expect(controller.error, isNull);
      expect(imported.map((b) => b.blockType), [
        'heading_1',
        'numbered_list',
        'numbered_list',
        'code',
        'divider',
        'image',
        'paragraph',
      ]);
      expect(imported[1].ordered!.start, 3);
      expect(imported[2].ordered!.order, 3);
      expect(imported[3].code!.language, 'Dart');
      await controller.close();
      controller = CollabController.cses(
        config: config,
        gateway: const _OfflineGateway(),
      );
      await controller.initialize();
      expect(native.currentBlocks().map((b) => b.text), all.map((b) => b.text));
      expect(controller.error, isNull);
    } finally {
      await controller.close();
      await directory.delete(recursive: true);
    }
  });
}

/// 仅恢复本地正式文档的端口，不持有物理连接或订阅资源。
class _OfflineGateway implements CsesCollabGateway {
  /// 创建无网络的测试端口。
  const _OfflineGateway();

  /// 测试始终离线。
  @override
  bool get isConnected => false;

  /// 无连接事件，订阅由协同会话管理。
  @override
  Stream<bool> get connectionStates => const Stream.empty();

  /// 接受 [pageId]/[documentId]/[instanceId] 与 [callbacks]，不登记外部资源。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {}

  /// 对 [pageId] 的 [action]/[body] 保持离线返回 false，不发送或缓存。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) => false;

  /// [pageId] 不拥有资源，注销立即完成。
  @override
  Future<void> unregister(String pageId) async {}
}
