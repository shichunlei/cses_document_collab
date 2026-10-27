import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/collab_host_mention_ui.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 宿主UI契约、缺省行为与迟到选择隔离，不依赖Demo或内置选择器。
void main() {
  testWidgets(
    'absent avatar performs no request; host receives full sizing contract',
    (tester) async {
      final owner = Object();
      CollabRuntime.acquire(owner, const CollabHostServices());
      addTearDown(() => CollabRuntime.release(owner));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              expect(
                buildHostMentionAvatarSlot(
                  context,
                  userId: 'u1',
                  name: '原名',
                  size: 18,
                ),
                isNull,
              );
              return const SizedBox();
            },
          ),
        ),
      );
      CollabRuntime.acquire(
        owner,
        CollabHostServices(
          mentionAvatarBuilder:
              (
                context, {
                required userId,
                required name,
                required size,
                avatarUrl,
              }) {
                expect(
                  (userId, name, size, avatarUrl),
                  ('u1', '原名', 18.0, 'custom://avatar'),
                );
                return const ColoredBox(
                  key: ValueKey('injected'),
                  color: Colors.red,
                );
              },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: Builder(
              builder: (context) => buildHostMentionAvatarSlot(
                context,
                userId: 'u1',
                name: '原名',
                size: 18,
                avatarUrl: 'custom://avatar',
              )!,
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('injected'))),
        const Size(18, 18),
      );
      expect(find.byType(Image), findsNothing);
    },
  );

  for (final outcome in [
    'success',
    'cancel',
    'permission',
    'session',
    'disposed',
    'unmounted',
    'error',
  ]) {
    testWidgets('picker $outcome and duplicate invocation are isolated', (
      tester,
    ) async {
      final state = EditorState.blank();
      final owner = Object();
      final pending = Completer<CollabMentionUser?>();
      ValueListenable<bool>? permission;
      var calls = 0;
      final services = CollabHostServices(
        pickMentionUser: (context, {required keyword, required canEdit}) {
          calls++;
          expect(keyword, '张');
          permission = canEdit;
          return pending.future;
        },
      );
      CollabRuntime.acquire(owner, services);
      addTearDown(() {
        CollabRuntime.release(owner);
        if (!state.isDisposed) state.dispose();
      });
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      );
      final result = pickHostMentionUser(context, state, keyword: '张');
      expect(permission!.value, isTrue);
      expect(await pickHostMentionUser(context, state, keyword: '张'), isNull);
      expect(calls, 1);
      if (outcome == 'permission') {
        state.editable = false;
        expect(permission!.value, isFalse);
        state.editable = true;
        expect(permission!.value, isFalse);
      }
      if (outcome == 'session') {
        CollabRuntime.acquire(owner, const CollabHostServices());
      }
      if (outcome == 'disposed') {
        state.dispose();
        expect(permission!.value, isFalse);
      }
      if (outcome == 'unmounted') await tester.pumpWidget(const SizedBox());
      if (outcome == 'error') {
        final assertion = expectLater(result, throwsStateError);
        pending.completeError(StateError('host failed'));
        await assertion;
      } else {
        const user = CollabMentionUser(id: 'u1', name: '张三');
        pending.complete(outcome == 'cancel' ? null : user);
        expect(await result, outcome == 'success' ? user : null);
      }
      // A new call after completion is allowed; no stale busy flag is retained.
      if (outcome == 'success') {
        expect(
          await pickHostMentionUser(context, state, keyword: '张'),
          isNotNull,
        );
        expect(calls, 2);
      }
    });
  }
  testWidgets('no host picker or read-only editor never starts selection', (
    tester,
  ) async {
    final state = EditorState.blank();
    final owner = Object();
    CollabRuntime.acquire(owner, const CollabHostServices());
    addTearDown(() {
      state.dispose();
      CollabRuntime.release(owner);
    });
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(await pickHostMentionUser(context, state), isNull);
    CollabRuntime.acquire(
      owner,
      CollabHostServices(
        pickMentionUser: (context, {required keyword, required canEdit}) =>
            throw StateError('must not run'),
      ),
    );
    state.editable = false;
    expect(await pickHostMentionUser(context, state), isNull);
  });
}
