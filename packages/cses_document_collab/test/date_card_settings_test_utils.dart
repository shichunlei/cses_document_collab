import 'package:cses_document_collab/src/model/collab_date_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在借用 [tester] 的日期设置中，通过实际左右按钮选择目标 [style]。
/// [style]为桌面样式键；未注册时抛ArgumentError，按钮/回显未在12次内响应则测试失败。
Future<void> chooseDateCardStyle(WidgetTester tester, String style) async {
  final names = collabDateCardStyles.values.toList();
  final target = collabDateCardStyles[style];
  if (target == null) throw ArgumentError.value(style, 'style');
  for (var attempt = 0; attempt < names.length; attempt++) {
    final current = tester.widget<Text>(find.byKey(const ValueKey('date-card-style-name'))).data;
    if (current == target) return;
    final currentIndex = names.indexOf(current!);
    final targetIndex = names.indexOf(target);
    final forward = (targetIndex - currentIndex) % names.length;
    final backward = (currentIndex - targetIndex) % names.length;
    await tester.tap(find.byKey(ValueKey(forward <= backward ? 'date-card-style-next' : 'date-card-style-previous')));
    await tester.pump();
  }
  expect(tester.widget<Text>(find.byKey(const ValueKey('date-card-style-name'))).data, target);
}
