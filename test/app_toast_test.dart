import 'package:cses_common/flutter/feedback/toast_util.dart';
import 'package:cses_mobile_collab_demo/src/demo/app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证真实应用入口提供 Common 提示所需的全局浮层。
void main() {
  testWidgets('Common toast displays and expires in the demo app', (
    tester,
  ) async {
    await tester.pumpWidget(const CsesCollabDemoApp());
    await tester.pumpAndSettle();

    showToast(text: '打开会议页面');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('打开会议页面'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('打开会议页面'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
