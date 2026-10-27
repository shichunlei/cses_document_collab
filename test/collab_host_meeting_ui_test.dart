import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_host_meeting_ui.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_meeting_reference.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 宿主会议流程只返回值；包拒绝过期会话/权限结果且成对释放借出监听。
void main() {
  testWidgets(
    'missing picker does nothing; revoke invalidates pending result even after regrant',
    (tester) async {
      final editor = EditorState.blank();
      final owner = Object();
      final pending = Completer<CollabMeetingReference?>();
      var calls = 0;
      BuildContext? view;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              view = context;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(await pickHostMeetingReference(view!, editor), isNull);
      CollabRuntime.acquire(
        owner,
        CollabHostServices(
          pickMeetingReference: (context, {required canEdit}) {
            calls++;
            return pending.future;
          },
        ),
      );
      final picking = pickHostMeetingReference(view!, editor);
      expect(await pickHostMeetingReference(view!, editor), isNull);
      editor.editable = false;
      editor.editable = true;
      pending.complete(const CollabMeetingReference(meetingId: 'm1'));
      expect(await picking, isNull);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
      CollabRuntime.release(owner);
    },
  );
  testWidgets(
    'replaced host invalidates old selection and error remains observable',
    (tester) async {
      final editor = EditorState.blank();
      final owner = Object();
      final replacement = Object();
      final pending = Completer<CollabMeetingReference?>();
      BuildContext? view;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              view = context;
              return const SizedBox();
            },
          ),
        ),
      );
      CollabRuntime.acquire(
        owner,
        CollabHostServices(
          pickMeetingReference: (context, {required canEdit}) => pending.future,
        ),
      );
      final picking = pickHostMeetingReference(view!, editor);
      CollabRuntime.release(owner);
      CollabRuntime.acquire(
        replacement,
        CollabHostServices(
          pickMeetingReference: (context, {required canEdit}) async =>
              throw StateError('宿主失败'),
        ),
      );
      pending.complete(const CollabMeetingReference(meetingId: 'm1'));
      expect(await picking, isNull);
      await expectLater(
        pickHostMeetingReference(view!, editor),
        throwsStateError,
      );
      await tester.pumpWidget(const SizedBox());
      editor.dispose();
      CollabRuntime.release(replacement);
    },
  );
}
