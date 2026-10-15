import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/document_feedback_footer.dart';
import 'package:cses_document_collab/src/controller/document_feedback_controller.dart';
import 'package:cses_document_collab/src/model/collab_document_feedback.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证宿主事件、重复点击保护和异步退出边界，不加载原生库。
void main() {
  /// 用[services]和借用的[editor]构建文档[documentId]的内部文末视图。
  Widget buildFooter(
    CollabHostServices services,
    EditorState editor, {
    String documentId = 'doc-a',
  }) {
    final controller = DocumentFeedbackController(
      documentId: documentId,
      services: services,
    );
    addTearDown(controller.dispose);
    return MaterialApp(
      home: Scaffold(
        body: DocumentFeedbackFooter(
          key: ValueKey(documentId),
          controller: controller,
          editorState: editor,
        ),
      ),
    );
  }

  testWidgets(
    'loaded likes render yellow state, avatars and updated comment count',
    (tester) async {
      final editor = EditorState.blank();
      addTearDown(editor.dispose);
      final received = <Object>[];
      final initialLikes = CollabDocumentLikes(
        isLiked: true,
        members: [
          const CollabDocumentLikeMember(
            userId: 'u1',
            name: '春雷',
            avatarUrl: 'host-avatar',
          ),
        ],
      );
      final services = CollabHostServices(
        loadDocumentFeedback: (id) =>
            CollabDocumentFeedback(likes: initialLikes, commentCount: 3),
        mentionAvatarBuilder:
            (_, {required userId, required name, required size, avatarUrl}) {
              received.add([userId, name, size, avatarUrl]);
              return const Icon(
                Icons.person,
                key: ValueKey('host-like-avatar'),
              );
            },
        onDocumentLike: (id, likes) {
          expect(id, 'doc-a');
          expect(likes, same(initialLikes));
          expect(() => likes.members.clear(), throwsUnsupportedError);
          return CollabDocumentLikes();
        },
        onDocumentComment: (id, count) {
          expect(id, 'doc-a');
          expect(count, 3);
          return 5;
        },
      );
      await tester.pumpWidget(buildFooter(services, editor));
      await tester.pumpAndSettle();
      expect(find.text('你已赞'), findsOneWidget);
      expect(
        tester.getRect(find.text('你已赞')).center.dx,
        closeTo(
          tester.getRect(find.byKey(const ValueKey('document-like'))).center.dx,
          0.5,
        ),
      );
      expect(find.byTooltip('取消点赞'), findsOneWidget);
      expect(find.text('评论全文（3）'), findsOneWidget);
      expect(find.byKey(const ValueKey('host-like-avatar')), findsOneWidget);
      expect(received, contains(equals(['u1', '春雷', 28.0, 'host-avatar'])));
      final button = tester.widget<IconButton>(
        find.byKey(const ValueKey('document-like')),
      );
      expect(
        button.style!.backgroundColor!.resolve({}),
        const Color(0xFFFFC928),
      );
      await tester.tap(find.byKey(const ValueKey('document-comment')));
      await tester.pumpAndSettle();
      expect(find.text('评论全文（5）'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('document-like')));
      await tester.pumpAndSettle();
      expect(find.text('你已赞'), findsNothing);
      expect(find.text('真诚点赞，手留余香'), findsOneWidget);
      expect(
        tester.getRect(find.text('真诚点赞，手留余香')).center.dx,
        closeTo(
          tester.getRect(find.byKey(const ValueKey('document-like'))).center.dx,
          0.5,
        ),
      );
      expect(find.byKey(const ValueKey('document-like-members')), findsNothing);
      expect(find.text('评论全文（5）'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('initial failure disables actions and can be reloaded', (
    tester,
  ) async {
    final editor = EditorState.blank();
    addTearDown(editor.dispose);
    var attempts = 0;
    final services = CollabHostServices(
      onError: (_, _, _, _) {},
      loadDocumentFeedback: (_) {
        if (++attempts == 1) throw StateError('load failed');
        return CollabDocumentFeedback(
          likes: CollabDocumentLikes(),
          commentCount: 2,
        );
      },
      onDocumentLike: (_, likes) => likes,
    );
    await tester.pumpWidget(buildFooter(services, editor));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-like')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('评论全文（2）'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-like')))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('missing callbacks disable both buttons without an input', (
    tester,
  ) async {
    final editor = EditorState.blank();
    addTearDown(editor.dispose);
    await tester.pumpWidget(buildFooter(const CollabHostServices(), editor));
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('document-like')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('document-comment')),
          )
          .onPressed,
      isNull,
    );
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('waiting for host blocks both actions and survives page exit', (
    tester,
  ) async {
    final editor = EditorState.blank();
    addTearDown(editor.dispose);
    final completion = Completer<CollabDocumentLikes?>();
    final calls = <String>[];
    final services = CollabHostServices(
      onDocumentLike: (id, likes) {
        calls.add(id);
        return completion.future;
      },
      onDocumentComment: (id, count) {
        calls.add('comment:$id');
        return count;
      },
    );
    await tester.pumpWidget(buildFooter(services, editor));
    await tester.tap(find.byKey(const ValueKey('document-like')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('document-like')));
    await tester.tap(find.byKey(const ValueKey('document-comment')));
    expect(calls, ['doc-a']);
    await tester.pumpWidget(const SizedBox.shrink());
    completion.complete(null);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('host failures report, show retry and allow a second call', (
    tester,
  ) async {
    final editor = EditorState.blank();
    addTearDown(editor.dispose);
    final reports = <Object>[];
    var attempts = 0;
    final services = CollabHostServices(
      onError: (_, error, _, _) => reports.add(error),
      onDocumentComment: (_, count) async {
        if (++attempts == 1) throw StateError('host failure');
        return count;
      },
    );
    await tester.pumpWidget(buildFooter(services, editor));
    await tester.tap(find.byKey(const ValueKey('document-comment')));
    await tester.pumpAndSettle();
    expect(reports.single, isA<StateError>());
    expect(find.text('操作失败，请重试'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('document-comment')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late failure cannot show feedback on another document', (
    tester,
  ) async {
    final editor = EditorState.blank();
    addTearDown(editor.dispose);
    final completion = Completer<CollabDocumentLikes?>();
    final reports = <Object>[];
    final services = CollabHostServices(
      onError: (_, error, _, _) => reports.add(error),
      onDocumentLike: (_, likes) => completion.future,
    );
    await tester.pumpWidget(buildFooter(services, editor));
    await tester.tap(find.byKey(const ValueKey('document-like')));
    await tester.pumpWidget(buildFooter(services, editor, documentId: 'doc-b'));
    completion.completeError(StateError('old document failure'));
    await tester.pumpAndSettle();
    expect(reports, hasLength(1));
    expect(find.text('操作失败，请重试'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
