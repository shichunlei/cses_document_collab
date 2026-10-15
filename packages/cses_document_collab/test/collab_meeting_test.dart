import 'package:cses_document_collab/src/model/collab_meeting_reference.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证会议引用事务、冲突、窄屏面板与宿主导航。
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
    'patches retain null/missing values and undo relocates by identity',
    () async {
      for (final title in ['{}', '{"title":null}']) {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = _adapter(
          properties: title == '{}'
              ? '{"meetingId":"m1"}'
              : '{"meetingId":"m1","title":null}',
          onChanged: changes.add,
        );
        final state = adapter.editorState;
        final original = adapter.blocks.first.resource!.properties;
        expect(
          await changeCollabMeeting(state, 'meeting', {
            'meetingId': 'm1',
            'title': '新标题',
          }, expected: original),
          isTrue,
        );
        expect(
          changes.last.first.resource!.propertyEdits,
          '{"title":{"value":"新标题"}}',
        );
        final updated = adapter.blocks;
        await adapter.replaceFromRemote([updated.last, updated.first]);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(adapter.blocks.last.resource!.properties, original);
        state.undoManager.redo();
        await pumpEventQueue();
        expect(adapter.blocks.last.resource!.string('title'), '新标题');
        expect(
          await changeCollabMeeting(state, 'meeting', {
            'meetingId': 'm1',
            'title': '过期',
          }, expected: original),
          isFalse,
        );
        state.editable = false;
        expect(
          await changeCollabMeeting(state, 'meeting', {
            'meetingId': 'm1',
          }, expected: adapter.blocks.last.resource!.properties),
          isFalse,
        );
        state.editable = true;
        await adapter.replaceFromRemote([updated.last]);
        state.undoManager.undo();
        await pumpEventQueue();
        expect(adapter.blocks.length, 1);
        adapter.dispose();
      }
    },
  );
  test(
    'root/nested insertion, backspace and history preserve references',
    () async {
      for (final nested in [false, true]) {
        for (final text in ['', '保留正文']) {
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              if (nested)
                const CollabEditorBlock(
                  id: 'box',
                  blockType: 'callout',
                  text: '',
                ),
              CollabEditorBlock(
                id: 'source',
                parentId: nested ? 'box' : null,
                blockType: 'paragraph',
                text: text,
              ),
            ],
            onLocalBlocksChanged: (_) {},
          );
          final state = adapter.editorState;
          final landing = await insertCollabMeeting(
            state,
            Selection.single(path: nested ? [0, 0] : [0], startOffset: 0),
            {'meetingId': 'm1', 'title': '周会', 'number': '123456'},
          );
          final meeting = adapter.blocks.firstWhere(
            (b) => b.blockType == 'meeting',
          );
          expect(meeting.id, isNot('source'));
          expect(meeting.parentId, nested ? 'box' : null);
          expect(meeting.text, isEmpty);
          expect(meeting.resource!.string('meetingId'), 'm1');
          if (text.isNotEmpty) {
            expect(
              adapter.blocks.firstWhere((b) => b.id == 'source').text,
              text,
            );
          }
          state.selection = landing;
          expect(await deletePreviousUrlBackedBlock(state), isTrue);
          state.undoManager.undo();
          await pumpEventQueue();
          expect(adapter.blocks.any((b) => b.id == meeting.id), isTrue);
          state.undoManager.redo();
          await pumpEventQueue();
          expect(adapter.blocks.any((b) => b.id == meeting.id), isFalse);
          adapter.dispose();
        }
      }
      expect(CollabMeeting.valid({'meetingId': ''}), isFalse);
      expect(CollabMeeting.valid({'meetingId': '😀' * 129}), isFalse);
      expect(
        CollabMeeting.valid({'meetingId': 'm', 'title': '😀' * 1001}),
        isFalse,
      );
    },
  );
  testWidgets(
    'more menu cancels without writes and inserts at relocated bookmark',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final owner = Object();
      var calls = 0;
      CollabRuntime.acquire(
        owner,
        CollabHostServices(
          pickMeetingReference: (context, {required canEdit}) async {
            calls++;
            ModalRoute<CollabMeetingReference>? route;
            final result = await showModalBottomSheet<CollabMeetingReference>(
              context: context,
              builder: (context) {
                route = ModalRoute.of(context);
                return TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    calls == 1
                        ? null
                        : const CollabMeetingReference(
                            meetingId: 'm1',
                            title: '会议卡片',
                          ),
                  ),
                  child: const Text('宿主确认'),
                );
              },
            );
            await route?.completed;
            return result;
          },
        ),
      );
      addTearDown(() => CollabRuntime.release(owner));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_tail],
        onLocalBlocksChanged: (_) {},
      );
      final controller = _ReadyController(adapter.editorState);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 150));
        controller.dispose();
        adapter.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(home: CollaborativeEditorPage(collab: controller)),
      );
      await tester.pumpAndSettle();
      adapter.editorState.selection = Selection.single(
        path: [0],
        startOffset: 1,
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(CollaborativeEditorPage));
      var completed = false;
      final adding = showEditorAddBlockSheet(
        context,
        adapter.editorState,
      ).then((_) => completed = true);
      await tester.pumpAndSettle();
      final entry = find.byKey(const ValueKey('editor-shortcut-meeting'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await tester.tap(find.text('宿主确认'));
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 1);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      await adapter.replaceFromRemote([
        const CollabEditorBlock(
          id: 'remote',
          blockType: 'paragraph',
          text: '远端',
        ),
        _tail,
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.text('宿主确认'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 8 && !completed; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(completed, isTrue);
      await adding;
      expect(adapter.blocks.map((b) => b.blockType), [
        'paragraph',
        'paragraph',
        'meeting',
        'paragraph',
      ]);
      expect(adapter.blocks[2].resource!.string('meetingId'), 'm1');
      expect(adapter.editorState.selection!.start.path, [3]);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
    },
  );
  testWidgets(
    'only primary button navigates without reopening a hidden keyboard',
    (tester) async {
      final owner = Object();
      var calls = 0;
      CollabRuntime.acquire(
        owner,
        CollabHostServices(
          onMeetingCardTap: (id, title, number) {
            expect([id, title, number], ['m1', '周会', '123456']);
            calls++;
          },
        ),
      );
      final adapter = _adapter();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
        CollabRuntime.release(owner);
      });
      await _mountCard(tester, adapter);
      expect(find.text('编辑引用'), findsNothing);
      final card = find.byKey(const ValueKey('collab-meeting-meeting'));
      final bounds = tester.getRect(card);
      final points = [
        bounds.topLeft + const Offset(20, 3),
        Offset(bounds.left + 2, bounds.center.dy),
        tester.getCenter(find.text('周会')),
        tester.getCenter(find.text('会议编号：123456')),
      ];
      for (final point in points) {
        // Retain a real text caret while the soft keyboard is hidden, as after Android back.
        final selection = adapter.editorState.updateSelectionWithReason(
          Selection.single(path: [1], startOffset: 1),
          reason: SelectionUpdateReason.uiEvent,
        );
        await tester.pump();
        await selection;
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.testTextInput.hasAnyClients, isTrue);
        tester.testTextInput.hide();
        tester.testTextInput.log.clear();
        final before = calls;
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        expect(calls, before, reason: 'card background must not navigate');
        await tester.tap(find.byKey(const ValueKey('meeting-open-meeting')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        expect(calls, before + 1);
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.show',
          ),
          isEmpty,
        );
        expect(tester.testTextInput.isVisible, isFalse);
        expect(adapter.editorState.selection, isNull);
      }
      // Explicitly selecting text again still opens a working input client.
      final selection = adapter.editorState.updateSelectionWithReason(
        Selection.single(path: [1], startOffset: 1),
        reason: SelectionUpdateReason.uiEvent,
      );
      await tester.pump();
      await selection;
      await tester.pumpAndSettle();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(adapter.blocks.first.resource!.string('meetingId'), 'm1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending or failed card callback keeps keyboard hidden and disables duplicate actions',
    (tester) async {
      final owner = Object();
      final pending = Completer<void>();
      final errors = <Object>[];
      var calls = 0;
      CollabRuntime.acquire(
        owner,
        CollabHostServices(
          onMeetingCardTap: (_, _, _) {
            calls++;
            return pending.future;
          },
          onError: (_, error, _, _) => errors.add(error),
        ),
      );
      final adapter = _adapter();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
        CollabRuntime.release(owner);
      });
      await _mountCard(tester, adapter);
      final button = find.byKey(const ValueKey('meeting-open-meeting'));
      final open = tester.widget<FilledButton>(button).onPressed!;
      tester.testTextInput.log.clear();
      open();
      open();
      await tester.pump();
      expect(calls, 1);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('meeting-delete-meeting')),
            )
            .onPressed,
        isNull,
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      pending.completeError(StateError('expected host failure'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(errors, hasLength(1));
      expect(find.text('打开会议失败，请重试'), findsOneWidget);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.show',
        ),
        isEmpty,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      expect(adapter.blocks.first.blockType, 'meeting');
      expect(tester.takeException(), isNull);
    },
  );

  for (final nested in [false, true]) {
    testWidgets(
      'bottom delete removes reference without navigating and undo/redo works, nested=$nested',
      (tester) async {
        final owner = Object();
        var calls = 0;
        CollabRuntime.acquire(
          owner,
          CollabHostServices(
            onMeetingCardTap: (_, _, _) {
              calls++;
            },
          ),
        );
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [
            if (nested)
              const CollabEditorBlock(
                id: 'box',
                blockType: 'callout',
                text: '',
              ),
            CollabEditorBlock(
              id: 'meeting',
              parentId: nested ? 'box' : null,
              blockType: 'meeting',
              text: '',
              resource: CollabResource.fromValues({
                'meetingId': 'm1',
                'title': '周会',
                'number': '123456',
              }),
            ),
          ],
          onLocalBlocksChanged: (_) {},
        );
        final controller = _ReadyController(adapter.editorState);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
          adapter.dispose();
          CollabRuntime.release(owner);
        });
        await tester.pumpWidget(
          MaterialApp(home: CollaborativeEditorPage(collab: controller)),
        );
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('collab-meeting-meeting'));
        final delete = find.byKey(const ValueKey('meeting-delete-meeting'));
        final cardRect = tester.getRect(card);
        final deleteRect = tester.getRect(delete);
        expect(deleteRect.left, lessThan(cardRect.center.dx));
        expect(deleteRect.bottom, greaterThan(cardRect.center.dy));
        await tester.tap(delete);
        await tester.pumpAndSettle();
        expect(calls, 0);
        expect(adapter.blocks.where((b) => b.blockType == 'meeting'), isEmpty);
        expect(adapter.blocks.last.blockType, 'paragraph');
        expect(adapter.blocks.last.parentId, nested ? 'box' : null);
        expect(find.byType(BottomSheet), findsNothing);
        adapter.editorState.undoManager.undo();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pumpAndSettle();
        expect(
          adapter.blocks
              .firstWhere((block) => block.blockType == 'meeting')
              .resource!
              .string('meetingId'),
          'm1',
        );
        expect(find.text('删除引用'), findsOneWidget);
        adapter.editorState.undoManager.redo();
        await tester.runAsync(() => pumpEventQueue());
        await tester.pumpAndSettle();
        expect(adapter.blocks.where((b) => b.blockType == 'meeting'), isEmpty);
        expect(calls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'preview or permission revocation hides delete and stale delete cannot write',
    (tester) async {
      final adapter = _adapter();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
      });
      await _mountCard(tester, adapter);
      final delete = find.byKey(const ValueKey('meeting-delete-meeting'));
      final staleAction = tester.widget<TextButton>(delete).onPressed!;
      adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expect(delete, findsNothing);
      staleAction();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.blockType, 'meeting');
      adapter.editorState.editable = true;
      await tester.pumpAndSettle();
      final oldAction = tester.widget<TextButton>(delete).onPressed!;
      await adapter.replaceFromRemote([_meeting('远端已变'), _tail]);
      await tester.pumpAndSettle();
      oldAction();
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.resource!.string('title'), '远端已变');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('delete remains available without host callback', (tester) async {
    final adapter = _adapter();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      adapter.dispose();
    });
    await _mountCard(tester, adapter);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('meeting-open-meeting')),
    );
    expect(button.onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('meeting-delete-meeting')));
    await tester.pumpAndSettle();
    expect(adapter.blocks.map((b) => b.id), ['tail']);
  });
  testWidgets(
    'card navigation works in preview, suppresses repeated taps and reports failure',
    (tester) async {
      final owner = Object();
      final pending = Completer<void>();
      final errors = <Object>[];
      var count = 0;
      CollabRuntime.acquire(
        owner,
        CollabHostServices(
          onMeetingCardTap: (id, title, number) {
            expect([id, title, number], ['m1', '周会', '123456']);
            count++;
            return pending.future;
          },
          onError: (_, error, stack, tag) => errors.add(error),
        ),
      );
      final adapter = _adapter();
      adapter.editorState.editable = false;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AppFlowyEditor(
                editable: false,
                editorState: adapter.editorState,
                blockComponentBuilders: {
                  ...standardBlockComponentBuilderMap,
                  collabMeetingType: CollabMeetingBlockComponentBuilder(),
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('周会'), findsOneWidget);
        expect(find.text('会议编号：123456'), findsOneWidget);
        expect(find.text('编辑引用'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('meeting-open-meeting')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('meeting-open-meeting')));
        await tester.pump();
        expect(count, 1);
        pending.completeError(StateError('失败'));
        await tester.pumpAndSettle();
        expect(errors.length, 1);
        expect(find.text('打开会议失败，请重试'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        adapter.dispose();
        CollabRuntime.release(owner);
      }
    },
  );
}

/// 使用 [title] 构造会议快照，仅使用合成身份。
CollabEditorBlock _meeting(String title) => CollabEditorBlock(
  id: 'meeting',
  blockType: 'meeting',
  text: '',
  resource: CollabResource.fromValues({
    'meetingId': 'm1',
    'title': title,
    'number': '123456',
  }),
);

/// 普通后置正文供稳定身份和插入验证。
const _tail = CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '正文');

/// 创建由测试拥有的适配器；[properties] 可覆盖原始属性，[onChanged] 接收本地提交快照。
AppFlowyBlockEditorAdapter _adapter({
  String? properties,
  void Function(List<CollabEditorBlock>)? onChanged,
}) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    properties == null
        ? _meeting('周会')
        : CollabEditorBlock(
            id: 'meeting',
            blockType: 'meeting',
            text: '',
            resource: CollabResource(properties: properties),
          ),
    _tail,
  ],
  onLocalBlocksChanged: onChanged ?? (_) {},
);

/// 就绪页面测试借用编辑器，不初始化连接。
class _ReadyController extends CollabController {
  /// [state] 由测试创建和释放，控制器只借用。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');

  /// 测试拥有的编辑器。
  final EditorState state;

  /// 返回已准备的借用编辑器。
  @override
  EditorState get editorState => state;

  /// 测试投影已准备。
  @override
  bool get initialized => true;

  /// 测试宿主允许编辑。
  @override
  bool get canEdit => true;
}

/// 在[tester]中挂载[adapter]借用的真实编辑器；资源由测试结束时释放。
Future<void> _mountCard(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AppFlowyEditor(
          editorState: adapter.editorState,
          editable: adapter.editorState.editable,
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            collabMeetingType: CollabMeetingBlockComponentBuilder(),
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
