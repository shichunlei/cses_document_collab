import 'dart:async';

import 'package:cses_document_collab/src/controller/document_feedback_controller.dart';
import 'package:cses_document_collab/src/model/collab_document_feedback.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证宿主快照的归属、串行操作和关闭边界，不使用原生文档。
void main() {
  test('likes copy member lists and comment counts reject negative values', () {
    final members = [const CollabDocumentLikeMember(userId: 'u1', name: '一')];
    final likes = CollabDocumentLikes(members: members);
    members.clear();
    expect(likes.members, hasLength(1));
    expect(() => likes.members.clear(), throwsUnsupportedError);
    expect(
      () => CollabDocumentFeedback(likes: likes, commentCount: -1),
      throwsRangeError,
    );
  });

  test(
    'callbacks see current state and null or invalid results retain it',
    () async {
      var calls = 0;
      final errors = <Object>[];
      final controller = DocumentFeedbackController(
        documentId: 'doc',
        services: CollabHostServices(
          onError: (_, error, _, _) => errors.add(error),
          onDocumentLike: (_, likes) => CollabDocumentLikes(
            isLiked: true,
            members: [const CollabDocumentLikeMember(userId: 'u1', name: '一')],
          ),
          onDocumentComment: (_, count) {
            expect(count, calls == 0 ? 0 : 8);
            return switch (calls++) {
              0 => 8,
              1 => null,
              _ => -1,
            };
          },
        ),
      );
      addTearDown(controller.close);
      await controller.toggleLike();
      await controller.openComments();
      await controller.openComments();
      expect(controller.value.commentCount, 8);
      expect(controller.value.likes.isLiked, isTrue);
      await controller.openComments();
      expect(controller.value.commentCount, 8);
      expect(controller.error, '操作失败，请重试');
      expect(errors.single, isA<RangeError>());
    },
  );

  test(
    'pending writes block repeat actions and refresh; load occurs once',
    () async {
      final result = Completer<CollabDocumentLikes?>();
      var loads = 0;
      var likes = 0;
      var comments = 0;
      final controller = DocumentFeedbackController(
        documentId: 'doc',
        services: CollabHostServices(
          loadDocumentFeedback: (_) {
            loads++;
            return CollabDocumentFeedback(likes: CollabDocumentLikes());
          },
          onDocumentLike: (_, current) {
            likes++;
            return result.future;
          },
          onDocumentComment: (_, count) {
            comments++;
            return count;
          },
        ),
      );
      addTearDown(controller.close);
      await controller.ensureLoaded();
      await controller.ensureLoaded();
      final pending = controller.toggleLike();
      final duplicate = controller.toggleLike();
      final refresh = controller.refresh();
      final comment = controller.openComments();
      await Future<void>.delayed(Duration.zero);
      expect(controller.busy, isTrue);
      expect(likes, 1);
      expect(comments, 0);
      expect(loads, 1);
      result.complete(CollabDocumentLikes(isLiked: true));
      await Future.wait([pending, duplicate, refresh, comment]);
      expect(controller.value.likes.isLiked, isTrue);
    },
  );

  test('close waits for host operation and discards its late result', () async {
    final result = Completer<CollabDocumentLikes?>();
    final started = Completer<void>();
    final controller = DocumentFeedbackController(
      documentId: 'old',
      services: CollabHostServices(
        onDocumentLike: (_, likes) {
          started.complete();
          return result.future;
        },
      ),
    );
    final pending = controller.toggleLike();
    await started.future;
    var closed = false;
    final closing = controller.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    result.complete(CollabDocumentLikes(isLiked: true));
    await pending;
    await closing;
    expect(closed, isTrue);
    expect(controller.value.likes.isLiked, isFalse);
    await controller.close();
  });
}
