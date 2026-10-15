import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_inline_entity_mention.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 业务实体原子展示、完整属性历史和远端冲突回归；测试不访问业务服务。
void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });
  for (final kind in ['meeting', 'task', 'doc']) {
    test(
      '$kind delete undo after reorder restores full atom; plain input stays plain',
      () async {
        final adapter = _adapter(kind);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        final body = state.document.first!;
        final target = CollabEntityMentionTarget.capture(body, 3)!;
        expect(CollabUserMentionTarget.capture(body, 3), isNull);
        expect(CollabEntityMentionTarget.capture(body, 2), isNull);
        final original = adapter.blocks.first.segments[1];
        expect(await deleteCollabEntityMention(state, target), isTrue);
        expect(adapter.blocks.first.text, '前😀后');
        await adapter.replaceFromRemote([adapter.blocks[1], adapter.blocks[0]]);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(adapter.blocks.last.segments[1], original);
        state.undoManager.redo();
        await pumpEventQueue();
        expect(adapter.blocks.last.text, '前😀后');
        state.undoManager.undo();
        await pumpEventQueue();
        final node = state.document.last!;
        final attrs = original.attributes;
        final delta = Delta()..insert('\uFFFCA😀', attributes: attrs);
        await state.apply(
          state.transaction..updateNode(node, {'delta': delta.toJson()}),
        );
        expect(
          adapter.blocks.last.segments.where((s) => s.mentionType == kind),
          hasLength(1),
        );
        expect(adapter.blocks.last.segments.last.mentionType, isNull);
        expect(adapter.blocks.last.segments.last.mentionAttributes, isNull);
      },
    );

    test(
      '$kind stale status, text or permissions reject deletion and history',
      () async {
        final adapter = _adapter(kind);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        final target = CollabEntityMentionTarget.capture(
          state.document.first!,
          3,
        )!;
        await deleteCollabEntityMention(state, target);
        await adapter.replaceFromRemote([_body(kind, status: '远端更新'), _tail]);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(
          adapter.blocks.first.segments[1].mentionAttributes,
          contains('远端更新'),
        );
        expect(await deleteCollabEntityMention(state, target), isFalse);
        final current = CollabEntityMentionTarget.capture(
          state.document.first!,
          3,
        )!;
        state.editable = false;
        expect(await deleteCollabEntityMention(state, current), isFalse);
      },
    );

    testWidgets(
      '$kind name renders in narrow large text and preview prevents delete',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        tester.platformDispatcher.textScaleFactorTestValue = 1.5;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final adapter = _adapter(kind);
        final controller = _ReadyController(adapter.editorState);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 150));
          controller.dispose();
          adapter.dispose();
          await tester.binding.setSurfaceSize(null);
        });
        await tester.pumpWidget(
          MaterialApp(home: CollaborativeEditorPage(collab: controller)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(CollabInlineEntityMention), findsOneWidget);
        expect(find.text('$kind名称'), findsOneWidget);
        expect(find.text('@$kind名称'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('collab-inline-entity-body-3')),
        );
        await tester.pumpAndSettle();
        expect(find.text('引用ID：$kind-id'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('entity-mention-delete')));
        await tester.pumpAndSettle();
        expect(adapter.blocks.first.text, '前😀后');
        adapter.editorState.undoManager.undo();
        await tester.pumpAndSettle();
        await tester.tap(find.text('预览'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('collab-inline-entity-body-3')),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('entity-mention-delete')),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

/// 已知后置正文，验证稳定块ID不依赖路径。
const _tail = CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '后文');

/// 根据 [kind] 构造单字符实体；[status] 改变完整业务属性，用于冲突验证。
CollabEditorBlock _body(String kind, {String status = '未开始'}) =>
    CollabEditorBlock(
      id: 'body',
      blockType: 'paragraph',
      text: '前😀\uFFFC后',
      segments: [
        const CollabEditorTextSegment(text: '前😀'),
        CollabEditorTextSegment(
          text: '\uFFFC',
          inlineMention: '$kind名称',
          mentionId: '$kind-id',
          mentionType: kind,
          mentionAttributes: jsonEncode({
            'mentionType': kind,
            'mentionId': '$kind-id',
            'status': {'name': status},
            'number': '123456',
            'custom': true,
          }),
        ),
        const CollabEditorTextSegment(text: '后'),
      ],
    );

/// 创建 [kind] 类型测试适配器；调用方负责释放其编辑器。
AppFlowyBlockEditorAdapter _adapter(String kind) => AppFlowyBlockEditorAdapter(
  initialBlocks: [_body(kind), _tail],
  onLocalBlocksChanged: (_) {},
);

/// 借用测试编辑器展示真实页面，不拥有原生连接。
class _ReadyController extends CollabController {
  /// [state] 由测试持有并释放，不转移所有权。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');

  /// 测试持有的编辑器。
  final EditorState state;

  /// 返回借用的编辑器，不初始化原生资源。
  @override
  EditorState get editorState => state;

  /// 测试投影已就绪。
  @override
  bool get initialized => true;

  /// 页面预览切换仍由EditorState控制，宿主测试权限允许编辑。
  @override
  bool get canEdit => true;
}
