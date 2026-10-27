import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_task_card_block.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_task_card_data.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证横排时间槽宽度有限，且详情Future完成时骨架/卡片/后续正文的几何保持。
/// 覆盖窄屏、大字和空字段。
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });
  for (final (width, scale) in [(390.0, 1.0), (320.0, 1.5), (280.0, 2.2)]) {
    for (final mode in ['full', 'sparse', 'missing', 'failure']) {
      testWidgets('task skeleton keeps geometry $width/$scale/$mode', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        try {
          await tester.binding.setSurfaceSize(Size(width, 1200));
          final pending = Completer<CollabTaskCardData?>();
          final owner = Object();
          CollabRuntime.acquire(
            owner,
            CollabHostServices(
              loadTaskCard: (_) => pending.future,
              onError: (_, _, _, _) {},
              mentionAvatarBuilder:
                  (
                    context, {
                    required userId,
                    required name,
                    required size,
                    avatarUrl,
                  }) => SizedBox(
                    width: size,
                    height: size,
                    child: const ColoredBox(color: Colors.blue),
                  ),
            ),
          );
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              CollabEditorBlock(
                id: 'geometry',
                blockType: 'task',
                text: '',
                resource: CollabResource.fromValues({
                  'taskId': 'task',
                  'title': '短标题',
                }),
              ),
              const CollabEditorBlock(
                id: 'after',
                blockType: 'paragraph',
                text: '任务后正文',
              ),
            ],
            onLocalBlocksChanged: (_) =>
                fail('loading must not edit the document'),
          );
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            adapter.dispose();
            CollabRuntime.release(owner);
            await tester.binding.setSurfaceSize(null);
          });
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: AppFlowyEditor(
                  editorState: adapter.editorState,
                  disableKeyboardService: true,
                  editorStyle: const EditorStyle.mobile(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                  ),
                  blockComponentBuilders: {
                    ...standardBlockComponentBuilderMap,
                    'task': CollabTaskCardBlockComponentBuilder(),
                  },
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.bySemanticsLabel(RegExp('任务加载中')), findsOneWidget);
          expect(find.byType(CircularProgressIndicator), findsNothing);
          final surface = find.byKey(
            const ValueKey('task-card-surface-geometry'),
          );
          final before = tester.getRect(surface);
          final tail = find.text('任务后正文', findRichText: true);
          final tailTop = tester.getTopLeft(tail).dy;
          final rows = {
            for (final name in ['people', 'title', 'start', 'end', 'footer'])
              name: tester.getRect(
                find.byKey(ValueKey('task-$name-row-geometry')),
              ),
          };
          final start = rows['start']!;
          final end = rows['end']!;
          expect(start.width.isFinite, isTrue);
          expect(start.width, greaterThan(0));
          expect(end.width, closeTo(start.width, .01));
          expect(start.top, closeTo(end.top, .01));
          expect(end.left - start.right, closeTo(5, .01));
          expect(start.left, greaterThanOrEqualTo(before.left));
          expect(end.right, lessThanOrEqualTo(before.right));
          if (mode == 'failure') {
            pending.completeError(StateError('fixture failure'));
          } else if (mode == 'missing') {
            pending.complete(null);
          } else {
            pending.complete(
              CollabTaskCardData(
                taskId: 'task',
                title: mode == 'full' ? '很长的任务名称需要两行显示但不能让正文下移以及骨架高度改变' : '短标题',
                priority: mode == 'full'
                    ? const CollabTaskCardTag(name: '很长的优先级标签')
                    : null,
                status: mode == 'full'
                    ? const CollabTaskCardTag(name: '很长的任务状态名称')
                    : null,
                startTime: mode == 'full'
                    ? DateTime(2026, 10, 18, 12, 30)
                    : null,
                endTime: mode == 'full' ? DateTime(2026, 10, 20, 23, 59) : null,
                progress: mode == 'full' ? 100 : null,
                fileCount: mode == 'full' ? 9999 : null,
                subTaskCount: mode == 'full' ? 9999 : null,
                leaders: mode == 'full'
                    ? List.generate(
                        4,
                        (i) => CollabMentionUser(id: 'u$i', name: '人'),
                      )
                    : const [],
                path: mode == 'full'
                    ? const [CollabTaskCardPath(name: '很长的路径名称', type: 'space')]
                    : const [],
              ),
            );
          }
          await tester.pumpAndSettle();
          expect(tester.getRect(surface), before);
          expect(tester.getTopLeft(tail).dy, closeTo(tailTop, .01));
          for (final name in rows.keys) {
            expect(
              tester.getRect(find.byKey(ValueKey('task-$name-row-geometry'))),
              rows[name],
            );
          }
          expect(find.bySemanticsLabel(RegExp('任务加载中')), findsNothing);
          if (mode == 'failure') expect(find.text('任务加载失败'), findsOneWidget);
          if (mode == 'missing') expect(find.text('任务不存在或已删除'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
