import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用真实控制器、FRB、SQLite及Yjs夹具验证两个旧标题兼容P1。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    final library = File('rust/target/debug/libcses_collab_core.$suffix');
    expect(library.existsSync(), isTrue, reason: '先构建真实宿主Rust库，不跳过原生回归');
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
  });

  for (final position in ['start', 'middle', 'end']) {
    test(
      'legacy heading splits at $position with valid new props and durable history',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'legacy-heading-',
        );
        final gateway = _Gateway('heading');
        final config = _config(directory);
        final errors = <Object>[];
        final controller = CollabController.cses(
          config: config,
          gateway: gateway,
          services: CollabHostServices(
            onError: (_, error, _, _) => errors.add(error),
          ),
        );
        CollabController? reopened;
        try {
          await controller.initialize();
          gateway.sync();
          await Future<void>.delayed(Duration.zero);
          expect(controller.status, ConnectionStatus.online);
          final before = native.currentBlocks();
          final source = before.firstWhere((b) => b.id == 'p1');
          final beforeIds = before.map((b) => b.id).toSet();
          expect(source.blockType, 'heading_6');
          expect(_props(source)['heading'], 9);
          final index = before.indexOf(source);
          final offset = switch (position) {
            'start' => 0,
            'middle' => 1,
            _ => source.text.length,
          };
          controller.editorState.selection = Selection.single(
            path: [index],
            startOffset: offset,
          );
          expect(
            await handleCollabParagraphEnter(controller.editorState),
            isTrue,
          );
          await Future<void>.delayed(Duration.zero);
          expect(errors, isEmpty);
          expect(controller.error, isNull);
          final after = native.currentBlocks();
          expect(after, hasLength(before.length + 1));
          final created = after.singleWhere((b) => !beforeIds.contains(b.id));
          expect(created.blockType, 'heading_6');
          expect(_props(created)['heading'], 6);
          expect(_props(after.firstWhere((b) => b.id == 'p1'))['heading'], 9);
          expect(
            after
                .where((b) => b.id == source.id || b.id == created.id)
                .map((b) => b.text)
                .join(),
            source.text,
          );

          await controller.undo();
          expect(
            native.currentBlocks().map((b) => b.id),
            before.map((b) => b.id),
          );
          expect(
            native.currentBlocks().firstWhere((b) => b.id == 'p1').text,
            source.text,
          );
          expect(
            _props(
              native.currentBlocks().firstWhere((b) => b.id == 'p1'),
            )['heading'],
            9,
          );
          await controller.redo();
          expect(
            native.currentBlocks().map((b) => b.id),
            after.map((b) => b.id),
          );
          expect(
            _props(
              native.currentBlocks().firstWhere((b) => b.id == created.id),
            )['heading'],
            6,
          );

          await controller.close();
          reopened = CollabController.cses(config: config, gateway: gateway);
          await reopened.initialize();
          expect(
            native.currentBlocks().map((b) => b.id),
            after.map((b) => b.id),
          );
          expect(
            _props(
              native.currentBlocks().firstWhere((b) => b.id == 'p1'),
            )['heading'],
            9,
          );
          expect(
            _props(
              native.currentBlocks().firstWhere((b) => b.id == created.id),
            )['heading'],
            6,
          );
        } finally {
          await reopened?.close();
          await controller.close();
          await gateway.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  for (final fixture in ['ordered-headings', 'ordered-missing-orders']) {
    test(
      'legacy ordered groups survive $fixture handshake, resync, history and reopen',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'legacy-ordered-',
        );
        final gateway = _Gateway(fixture);
        final config = _config(directory);
        final errors = <Object>[];
        final controller = CollabController.cses(
          config: config,
          gateway: gateway,
          services: CollabHostServices(
            onError: (_, error, _, _) => errors.add(error),
          ),
        );
        CollabController? reopened;
        try {
          await controller.initialize();
          gateway.sync();
          await Future<void>.delayed(Duration.zero);
          expect(controller.status, ConnectionStatus.online);
          _expectOrderedGroups();
          expect(gateway.updates, hasLength(1));
          if (fixture == 'ordered-headings') {
            expect(
              native.encodeStateVector(),
              gateway.vector,
              reason: '正确旧编号握手不得产生新的共享写入',
            );
          } else {
            expect(
              native.encodeStateVector(),
              isNot(gateway.vector),
              reason: '确实缺失的编号仍须修复',
            );
          }
          final vector = native.encodeStateVector();
          native.applyBlockSnapshot(blocks: native.currentBlocks());
          expect(native.encodeStateVector(), vector);
          _expectOrderedGroups();
          controller.resync();
          gateway.sync();
          await Future<void>.delayed(Duration.zero);
          _expectOrderedGroups();
          expect(native.encodeStateVector(), vector);

          final node = controller.editorState.document.first!;
          final beforeText = node.delta!.toPlainText();
          await controller.editorState.apply(
            controller.editorState.transaction
              ..insertText(node, beforeText.length, '!'),
          );
          _expectOrderedGroups();
          await controller.undo();
          _expectOrderedGroups();
          expect(native.currentBlocks().first.text, beforeText);
          await controller.redo();
          _expectOrderedGroups();
          expect(native.currentBlocks().first.text, '$beforeText!');
          expect(errors, isEmpty);
          expect(controller.error, isNull);
          await controller.close();
          reopened = CollabController.cses(config: config, gateway: gateway);
          await reopened.initialize();
          _expectOrderedGroups();
          expect(native.currentBlocks().first.text, '$beforeText!');
        } finally {
          await reopened?.close();
          await controller.close();
          await gateway.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}

/// 使用测试自有[directory]隔离SQLite；账号字段仅为虚构的缓存分区。
CollabDocumentConfig _config(Directory directory) => CollabDocumentConfig(
  documentId: 'fixture-doc',
  serverIdentity: 'wss://fixture.invalid/ws',
  companyId: 'company',
  userId: 'user',
  databasePath: '${directory.path}/updates.sqlite',
  editable: true,
);

/// 读取借用[block]的原始段落属性，不把投影的H6误作原始协议级别。
Map<String, dynamic> _props(native.CollabBlock block) =>
    jsonDecode(block.paragraphStyle?.properties ?? '{}')
        as Map<String, dynamic>;

/// 检查当前原生文档的编号组、原始heading、身份及修复标记，不修改数据。
void _expectOrderedGroups() {
  final blocks = native.currentBlocks();
  expect(blocks.map((b) => b.id), ['ordered-0', 'ordered-1', 'ordered-2']);
  expect(blocks.map((b) => b.ordered!.order), [0, 0, 1]);
  expect(blocks.map((b) => b.ordered!.heading), [6, 6, 6]);
  expect(blocks.map((b) => _props(b)['heading']), [7, 8, 7]);
  expect(blocks.every((b) => !b.ordered!.needsRepair), isTrue);
}

/// 测试拥有连接事件流；仅模拟消息路由，文档、持久化及历史均使用真实实现。
final class _Gateway implements CsesCollabGateway {
  /// 从生成清单选择[fixture]，使用准确服务端向量区分无变化补传与真实修复。
  _Gateway(String fixture) {
    final manifest =
        jsonDecode(
              File(
                'rust/tests/fixtures/legacy-heading-fixtures.json',
              ).readAsStringSync(),
            )
            as Map;
    final value = (manifest['fixtures'] as Map)[fixture] as Map;
    update = File('rust/tests/fixtures/${value['file']}').readAsBytesSync();
    vector = base64Decode(value['stateVector'] as String);
  }

  /// 本实例拥有的事件源，控制器只借用订阅；close等待其关闭。
  final events = StreamController<bool>.broadcast();
  final updates = <List<int>>[];
  late final List<int> update;
  late final List<int> vector;
  Map<String, void Function(Map<String, dynamic>)> callbacks = {};

  /// 测试主连接始终hello-ready，不创建物理连接。
  @override
  bool get isConnected => true;

  /// 借出测试事件流，控制器只负责取消自己的订阅。
  @override
  Stream<bool> get connectionStates => events.stream;

  /// 保存[pageId]所属[documentId]/[instanceId]的[callbacks]，不发网络消息。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    this.callbacks = callbacks;
  }

  /// 记录[pageId]的[action]/[body]补传，其他协议消息只模拟成功发送。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (action == 'collabUpdate') {
      updates.add(base64Decode(body['data'] as String));
    }
    return true;
  }

  /// 注销[pageId]的测试路由，不关闭测试拥有的连接事件源。
  @override
  Future<void> unregister(String pageId) async => callbacks = {};

  /// 同步交付夹具及其准确状态向量，不模拟正文或原生写入结果。
  void sync() => callbacks['collabSync']!({
    'data': base64Encode(update),
    'stateVector': base64Encode(vector),
  });

  /// 在所有借用控制器关闭后释放本实例拥有的事件源。
  Future<void> close() => events.close();
}
