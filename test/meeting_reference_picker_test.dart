import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/meeting_reference_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 宿主表单只返回引用；校验、取消、权限及资源由宿主页面负责。
void main() {
  testWidgets(
    'host validates reference and returns public value after route dismissal',
    (tester) async {
      final permission = ValueNotifier(true);
      CollabMeetingReference? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDemoMeetingReferencePicker(
                    context,
                    canEdit: permission,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加引用'));
      await tester.pumpAndSettle();
      expect(find.text('请填写有效会议 ID（最多512字节）'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('meeting-input-meetingId')),
        'm1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('meeting-input-title')),
        '周会',
      );
      await tester.enterText(
        find.byKey(const ValueKey('meeting-input-number')),
        '123456',
      );
      await tester.tap(find.text('添加引用'));
      await tester.pumpAndSettle();
      expect(result!.meetingId, 'm1');
      expect(result!.title, '周会');
      expect(result!.number, '123456');
      await tester.pumpWidget(const SizedBox());
      permission.dispose();
    },
  );
  testWidgets(
    'host narrow large-text form disables confirmation on revoke and cancels',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final permission = ValueNotifier(true);
      var completed = false;
      CollabMeetingReference? result;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDemoMeetingReferencePicker(
                    context,
                    canEdit: permission,
                  );
                  completed = true;
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      permission.value = false;
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '添加引用'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('meeting-close')));
      await tester.pumpAndSettle();
      expect(completed, isTrue);
      expect(result, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      permission.dispose();
    },
  );
}
