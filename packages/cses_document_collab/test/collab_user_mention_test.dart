import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_inline_mention.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_mention_tap.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用户原子、稳定历史、面板异步隔离及实际正文展示回归。
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
  test(
    'UTF16 atom, range replacement, plain typing, delete undo after reorder',
    () async {
      final adapter = _adapter();
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final target = CollabUserMentionTarget.capture(state.document.first!, 3)!;
      expect(target.userId, 'u1');
      expect(CollabUserMentionTarget.capture(state.document.first!, 2), isNull);
      expect(await deleteCollabUserMention(state, target), isTrue);
      expect(adapter.blocks.first.text, '前😀后');
      await adapter.replaceFromRemote([adapter.blocks[1], adapter.blocks[0]]);
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.last.segments[1].mentionId, 'u1');
      state.undoManager.redo();
      await pumpEventQueue();
      expect(adapter.blocks.last.text, '前😀后');
      final landing = await insertCollabUserMention(
        state,
        Selection.single(path: [1], startOffset: 3, endOffset: 1),
        const CollabMentionUser(id: 'u2', name: '李四'),
      );
      expect(landing!.start.offset, 3);
      expect(adapter.blocks.last.text, '前\uFFFC 后');
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.last.text, '前😀后');
      state.undoManager.redo();
      await pumpEventQueue();
      final node = state.getNodeAtPath([1])!;
      await state.apply(state.transaction..insertText(node, 3, '普通'));
      expect(adapter.blocks.last.text, '前\uFFFC 普通后');
      expect(
        adapter.blocks.last.segments.where((s) => s.mentionId != null).length,
        1,
      );
    },
  );
  test(
    'consecutive equal users are distinct atoms, UFFFC text is ordinary, inherited metadata is stripped from typing',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'body',
            blockType: 'paragraph',
            text: '\uFFFC\uFFFC\uFFFC😀',
            segments: [
              CollabEditorTextSegment(
                text: '\uFFFC',
                inlineMention: '张三',
                mentionId: 'u1',
              ),
              CollabEditorTextSegment(
                text: '\uFFFC',
                inlineMention: '张三',
                mentionId: 'u1',
              ),
              CollabEditorTextSegment(text: '\uFFFC😀'),
            ],
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      expect(
        adapter.blocks.single.segments.where((s) => s.mentionId != null).length,
        2,
      );
      expect(CollabUserMentionTarget.capture(state.document.first!, 2), isNull);
      final delta = Delta()
        ..insert(
          '\uFFFC\uFFFCA😀',
          attributes: {
            collabInlineMentionAttribute: '张三',
            collabMentionIdAttribute: 'u1',
          },
        );
      await state.apply(
        state.transaction
          ..updateNode(state.document.first!, {'delta': delta.toJson()}),
      );
      expect(
        adapter.blocks.single.segments.where((s) => s.mentionId != null).length,
        2,
      );
      expect(adapter.blocks.single.segments.last.mentionId, isNull);
    },
  );
  test(
    'stale identity and remote text forbid delete/history; read-only and code reject insert',
    () async {
      final adapter = _adapter();
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final target = CollabUserMentionTarget.capture(state.document.first!, 3)!;
      await deleteCollabUserMention(state, target);
      await adapter.replaceFromRemote([_body(userId: 'remote'), _tail]);
      state.undoManager.undo();
      await pumpEventQueue();
      expect(adapter.blocks.first.segments[1].mentionId, 'remote');
      expect(await deleteCollabUserMention(state, target), isFalse);
      state.editable = false;
      expect(
        await insertCollabUserMention(
          state,
          Selection.single(path: [0], startOffset: 0),
          _user,
        ),
        isNull,
      );
      state.editable = true;
      await adapter.replaceFromRemote(const [
        CollabEditorBlock(id: 'code', blockType: 'code', text: 'abc'),
      ]);
      expect(
        await insertCollabUserMention(
          state,
          Selection.single(path: [0], startOffset: 1),
          _user,
        ),
        isNull,
      );
    },
  );
  testWidgets(
    'missing picker leaves IME trigger to ordinary input and preserves toolbar selection',
    (tester) async {
      final adapter = await _mount(tester);
      final state = adapter.editorState;
      final selection = Selection.single(path: [1], startOffset: 1);
      state.selection = selection;
      final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
      final trigger = editor.characterShortcutEvents.firstWhere(
        (event) => event.key == 'cses-user-mention',
      );
      expect(await trigger.handler(state), isFalse);
      await showEditorUserMentionSheet(
        tester.element(find.byType(CollaborativeEditorPage)),
        state,
      );
      await tester.pumpAndSettle();
      expect(state.selection, selection);
      expect(adapter.blocks.last.text, '尾部');
      expect(find.text('宿主未提供人员选择器'), findsOneWidget);
    },
  );

  for (final asynchronous in [false, true]) {
    testWidgets(
      'host picker failure asynchronous=$asynchronous reports and restores without inserting',
      (tester) async {
        final adapter = await _mount(tester);
        final errors = <Object>[];
        _installPicker(
          services: CollabHostServices(
            onError: (_, error, _, _) => errors.add(error),
            pickMentionUser: (context, {required keyword, required canEdit}) {
              if (asynchronous) {
                return Future.error(StateError('host picker failed'));
              }
              throw StateError('host picker failed');
            },
          ),
        );
        final state = adapter.editorState;
        final selection = Selection.single(path: [1], startOffset: 1);
        state.selection = selection;
        final action = showEditorUserMentionSheet(
          tester.element(find.byType(CollaborativeEditorPage)),
          state,
        );
        await _finish(tester, action);
        expect(errors, hasLength(1));
        expect(state.selection, selection);
        expect(adapter.blocks.last.text, '尾部');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'host picker inserts at saved block after reorder; cancel restores backward selection',
    (tester) async {
      final adapter = await _mount(tester);
      _installPicker();
      final state = adapter.editorState;
      state.selection = Selection.single(
        path: [1],
        startOffset: 2,
        endOffset: 0,
      );
      final action = showEditorUserMentionSheet(
        tester.element(find.byType(CollaborativeEditorPage)),
        state,
      );
      await tester.pumpAndSettle();
      expect(state.selection, isNull);
      await adapter.replaceFromRemote([_tail, _body()]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mention-user-u1')));
      await tester.pumpAndSettle();
      await _finish(tester, action);
      expect(adapter.blocks.first.text, '\uFFFC ');
      expect(state.selection!.start.path, [0]);
      expect(state.selection!.start.offset, 2);
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.text, '尾部');
      final selection = Selection.single(
        path: [0],
        startOffset: 2,
        endOffset: 0,
      );
      state.selection = selection;
      final cancel = showEditorUserMentionSheet(
        tester.element(find.byType(CollaborativeEditorPage)),
        state,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mention-close')));
      await tester.pumpAndSettle();
      await _finish(tester, cancel);
      expect(state.selection, selection);
      expect(adapter.blocks.first.text, '尾部');
    },
  );
  testWidgets(
    'remote text change or permission revocation prevents insertion',
    (tester) async {
      final adapter = await _mount(tester);
      _installPicker();
      final state = adapter.editorState;
      state.selection = Selection.single(path: [1], startOffset: 1);
      final action = showEditorUserMentionSheet(
        tester.element(find.byType(CollaborativeEditorPage)),
        state,
      );
      await tester.pumpAndSettle();
      await adapter.replaceFromRemote([
        _body(),
        const CollabEditorBlock(
          id: 'tail',
          blockType: 'paragraph',
          text: '新尾部',
        ),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mention-user-u1')));
      await tester.pumpAndSettle();
      await _finish(tester, action);
      expect(adapter.blocks.last.text, '新尾部');
      state.selection = Selection.single(path: [1], startOffset: 1);
      final second = showEditorUserMentionSheet(
        tester.element(find.byType(CollaborativeEditorPage)),
        state,
      );
      await tester.pumpAndSettle();
      final controller =
          tester
                  .widget<CollaborativeEditorPage>(
                    find.byType(CollaborativeEditorPage),
                  )
                  .collab
              as _ReadyController;
      controller.allowed = false;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('当前不可编辑'), findsOneWidget);
      expect(find.byKey(const ValueKey('mention-user-u1')), findsNothing);
      controller.allowed = true;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mention-user-u1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mention-close')));
      await tester.pumpAndSettle();
      await _finish(tester, second);
      expect(adapter.blocks.last.text, '新尾部');
    },
  );
  testWidgets(
    'inline user card uses host avatar and click callback in edit and preview on narrow large text',
    (tester) async {
      final adapter = await _mount(tester);
      final sizes = <double>[];
      final taps = <CollabMentionTap>[];
      _installPicker(
        services: CollabHostServices(
          onMentionTap: taps.add,
          mentionAvatarBuilder:
              (
                context, {
                required userId,
                required name,
                required size,
                avatarUrl,
              }) {
                expect(userId, 'u1');
                expect(name, '张三');
                expect(avatarUrl, isNull);
                sizes.add(size);
                return const ColoredBox(
                  key: ValueKey('host-avatar'),
                  color: Colors.green,
                );
              },
        ),
      );
      await tester.binding.setSurfaceSize(const Size(320, 568));
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(find.byType(CollabInlineMention), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CollabInlineMention),
          matching: find.text('张三'),
        ),
        findsOneWidget,
      );
      expect(find.text('@张三'), findsNothing);
      for (final preview in [false, true]) {
        if (preview) {
          await tester.tap(find.text('预览'));
          await tester.pumpAndSettle();
        }
        await tester.tap(
          find.byKey(const ValueKey('collab-inline-mention-body-3')),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(taps, hasLength(preview ? 2 : 1));
        expect(taps.last.type, CollabMentionType.user);
        expect(taps.last.id, 'u1');
        expect(taps.last.name, '张三');
        expect(taps.last.attributes, {
          'mentionType': 'user',
          'mentionId': 'u1',
        });
        expect(adapter.blocks.first.text, '前😀\uFFFC后');
        expect(find.text('用户ID：u1'), findsNothing);
        expect(find.text('复制姓名'), findsNothing);
        expect(find.text('删除提及'), findsNothing);
      }
      expect(find.byKey(const ValueKey('host-avatar')), findsOneWidget);
      expect(sizes, isNotEmpty);
      expect(sizes, everyElement(lessThan(36)));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'more menu uses host picker and preserves original insertion location',
    (tester) async {
      final adapter = await _mount(tester);
      final owner = Object();
      CollabRuntime.acquire(
        owner,
        CollabHostServices(pickMentionUser: _pickUser),
      );
      addTearDown(() => CollabRuntime.release(owner));
      adapter.editorState.selection = Selection.single(
        path: [1],
        startOffset: 1,
      );
      final action = showEditorAddBlockSheet(
        tester.element(find.byType(CollaborativeEditorPage)),
        adapter.editorState,
      );
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('editor-shortcut-mention-more'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mention-user-u1')));
      await tester.pumpAndSettle();
      await _finish(tester, action);
      expect(adapter.blocks.last.text, '尾\uFFFC 部');
      expect(adapter.editorState.selection!.start.offset, 3);
    },
  );
  testWidgets(
    'platform IME @ inserts an atom and following typing stays ordinary',
    (tester) async {
      final adapter = await _mount(tester);
      final owner = Object();
      CollabRuntime.acquire(
        owner,
        CollabHostServices(pickMentionUser: _pickUser),
      );
      addTearDown(() => CollabRuntime.release(owner));
      final state = adapter.editorState;
      final selectionUpdate = state.updateSelectionWithReason(
        Selection.single(path: [1], startOffset: 1),
        reason: SelectionUpdateReason.uiEvent,
      );
      await tester.pump();
      await selectionUpdate;
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.testTextInput.hasAnyClients, isTrue);
      final editing = TextEditingValue.fromJSON(
        tester.testTextInput.editingState!,
      );
      final offset = editing.selection.extentOffset;
      tester.testTextInput.updateEditingValue(
        editing.copyWith(
          text: editing.text.replaceRange(offset, offset, '@'),
          selection: TextSelection.collapsed(offset: offset + 1),
          composing: TextRange.empty,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mention-user-u1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mention-user-u1')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(adapter.blocks.last.text, '尾\uFFFC 部');
      expect(state.selection!.start.offset, 3);
      final after = TextEditingValue.fromJSON(
        tester.testTextInput.editingState!,
      );
      final caret = after.selection.extentOffset;
      tester.testTextInput.updateEditingValue(
        after.copyWith(
          text: after.text.replaceRange(caret, caret, 'X'),
          selection: TextSelection.collapsed(offset: caret + 1),
          composing: TextRange.empty,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(adapter.blocks.last.text, '尾\uFFFC X部');
      expect(
        adapter.blocks.last.segments.where((s) => s.mentionId != null).length,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'typed @ opens picker, confirm replaces trigger, cancel leaves normal @',
    (tester) async {
      final adapter = await _mount(tester);
      final owner = Object();
      CollabRuntime.acquire(
        owner,
        CollabHostServices(pickMentionUser: _pickUser),
      );
      addTearDown(() => CollabRuntime.release(owner));
      final state = adapter.editorState;
      state.selection = Selection.single(path: [1], startOffset: 1);
      final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
      final trigger = editor.characterShortcutEvents.firstWhere(
        (e) => e.key == 'cses-user-mention',
      );
      final action = trigger.handler(state);
      await tester.pumpAndSettle();
      expect(adapter.blocks.last.text, '尾@部');
      await tester.tap(find.byKey(const ValueKey('mention-user-u1')));
      await tester.pumpAndSettle();
      expect(await _finish(tester, action), isTrue);
      expect(adapter.blocks.last.text, '尾\uFFFC 部');
      state.selection = Selection.single(path: [1], startOffset: 4);
      final cancel = trigger.handler(state);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mention-close')));
      await tester.pumpAndSettle();
      expect(await _finish(tester, cancel), isTrue);
      expect(adapter.blocks.last.text, '尾\uFFFC 部@');
    },
  );
}

/// 真实用户快照，测试不使用线上身份。
const _user = CollabMentionUser(id: 'u1', name: '张三');

/// 后置正文，验证模态定位独立于当前选区。
const _tail = CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '尾部');

/// 生成包含emoji与单字符用户的正文，[userId] 用于远端替换身份。
CollabEditorBlock _body({String userId = 'u1'}) => CollabEditorBlock(
  id: 'body',
  blockType: 'paragraph',
  text: '前😀\uFFFC后',
  segments: [
    const CollabEditorTextSegment(text: '前😀'),
    CollabEditorTextSegment(
      text: '\uFFFC',
      inlineMention: '张三',
      mentionId: userId,
      mentionAttributes: '{"mentionType":"user","mentionId":"$userId"}',
    ),
    const CollabEditorTextSegment(text: '后'),
  ],
);

/// 创建测试适配器，由每项测试释放。
AppFlowyBlockEditorAdapter _adapter() => AppFlowyBlockEditorAdapter(
  initialBlocks: [_body(), _tail],
  onLocalBlocksChanged: (_) {},
);

/// 在真实编辑页挂载，[tester] 负责驱动输入；创建方在测试结束释放资源。
Future<AppFlowyBlockEditorAdapter> _mount(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final adapter = _adapter();
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
  return adapter;
}

/// 测试页借用编辑器，不创建原生连接。
class _ReadyController extends CollabController {
  /// [state] 由测试持有和释放。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');
  final EditorState state;

  /// 提供测试编辑器，所有权不转移。
  @override
  EditorState get editorState => state;

  /// 测试正文结构有效。
  @override
  bool get initialized => true;

  /// 页可编辑，由页面模式切换控制EditorState。
  @override
  bool get canEdit => allowed;

  /// 测试宿主权限，修改后由测试通知页面。
  bool allowed = true;
}

/// 推进[tester]中的退场动画与Android键盘恢复定时器，再等待[future]完成。
Future<T> _finish<T>(WidgetTester tester, Future<T> future) async {
  var completed = false;
  final result = future.then((value) {
    completed = true;
    return value;
  });
  for (var i = 0; i < 12 && !completed; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(completed, isTrue);
  return result;
}

/// 安装测试宿主[services]，null使用固定选人回调；测试结束释放会话，界面仅为契约夹具。
void _installPicker({CollabHostServices? services}) {
  final owner = Object();
  CollabRuntime.acquire(
    owner,
    services ?? CollabHostServices(pickMentionUser: _pickUser),
  );
  addTearDown(() => CollabRuntime.release(owner));
}

/// 模拟宿主路由；[context] 为入口，[keyword] 不参与固定测试列表，
/// [canEdit] 控制确认；关闭动画后返回结果，不依赖包内人员选择器。
Future<CollabMentionUser?> _pickUser(
  BuildContext context, {
  required String keyword,
  required ValueListenable<bool> canEdit,
}) async {
  final route = DialogRoute<CollabMentionUser>(
    context: context,
    builder: (context) => AlertDialog(
      content: ValueListenableBuilder<bool>(
        valueListenable: canEdit,
        builder: (context, enabled, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (enabled)
              TextButton(
                key: const ValueKey('mention-user-u1'),
                onPressed: () => Navigator.pop(context, _user),
                child: const Text('张三'),
              )
            else
              const Text('当前不可编辑'),
            TextButton(
              key: const ValueKey('mention-close'),
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    ),
  );
  final user = await Navigator.of(context).push(route);
  await route.completed;
  return user;
}
