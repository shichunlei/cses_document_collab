import 'dart:ui' show SemanticsAction, Tristate;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_theme.dart';
import 'package:cses_document_collab/src/ui/modal/collab_switch_row.dart';

/// 验证 Row 菜单的输入、可用性、主题和开关独立命中契约。
void main() {
  testWidgets('menu row activates from padding and keyboard with button semantics', (tester) async {
    var calls = 0;
    await _mount(tester, CollabMenuRow(title: const Text('打开'), onTap: () => calls++));
    final row = find.byType(CollabMenuRow);
    await tester.tapAt(tester.getTopLeft(row) + const Offset(3, 3));
    expect(calls, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(calls, 2);
    final data = tester.getSemantics(row).getSemanticsData();
    expect(data.label, '打开');
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
  });

  for (final enabled in [true, false]) {
    testWidgets('menu row refuses activation when callback or enabled is absent: $enabled', (tester) async {
      var calls = 0;
      await _mount(
        tester,
        CollabMenuRow(title: const Text('删除'), enabled: enabled, onTap: enabled ? null : () => calls++),
      );
      await tester.tap(find.text('删除'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 0);
      final data = tester.getSemantics(find.byType(CollabMenuRow)).getSemanticsData();
      expect(data.flagsCollection.isEnabled, Tristate.isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
    });
  }

  testWidgets('only the switch toggles; labels, icon and row padding do nothing', (tester) async {
    final changes = <bool>[];
    var value = false;
    await _mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) => CollabSwitchRow(
          title: const Text('锁定内容块'),
          subtitle: const Text('锁定后保护内容'),
          leading: const Icon(LucideIcons.lockKeyhole),
          value: value,
          onChanged: (next) {
            changes.add(next);
            setState(() => value = next);
          },
        ),
      ),
    );
    await tester.tap(find.text('锁定内容块'));
    await tester.tap(find.text('锁定后保护内容'));
    await tester.tap(find.byIcon(LucideIcons.lockKeyhole));
    await tester.tapAt(tester.getTopLeft(find.byType(CollabSwitchRow)) + const Offset(3, 3));
    await tester.pump();
    expect(changes, isEmpty);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(changes, [true]);
    final data = tester.getSemantics(find.byType(CollabSwitchRow)).getSemanticsData();
    expect(data.label, contains('锁定内容块'));
    expect(data.label, contains('锁定后保护内容'));
    expect(data.flagsCollection.isToggled, Tristate.isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(changes, [true, false]);
  });

  testWidgets('disabled switch keeps its value and has no activation action', (tester) async {
    await _mount(tester, const CollabSwitchRow(title: Text('锁定内容块'), value: true, onChanged: null));
    await tester.tap(find.text('锁定内容块'));
    await tester.tap(find.byType(Switch));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    final data = tester.getSemantics(find.byType(CollabSwitchRow)).getSemanticsData();
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.tap), isFalse);
  });

  for (final dark in [false, true]) {
    testWidgets('danger colors and selection are preserved in theme: dark=$dark', (tester) async {
      await _mount(
        tester,
        Builder(
          builder: (context) => CollabMenuRow(
            selected: true,
            title: const Text('删除'),
            leading: const Icon(LucideIcons.trash2),
            trailing: const Icon(LucideIcons.check),
            textColor: CollabModalColors.of(context).danger,
            iconColor: CollabModalColors.of(context).danger,
            onTap: () {},
          ),
        ),
        dark: dark,
      );
      final text = tester.element(find.text('删除'));
      final icon = tester.element(find.byIcon(LucideIcons.trash2));
      final danger = CollabModalColors.of(text).danger;
      expect(DefaultTextStyle.of(text).style.color, danger);
      expect(IconTheme.of(icon).color, danger);
      await tester.pump();
      expect(
        tester.getSemantics(find.byType(CollabMenuRow)).getSemanticsData().flagsCollection.isSelected,
        Tristate.isTrue,
      );
    });
  }

  for (final compact in [false, true]) {
    testWidgets('row minimum height and density update: compact=$compact', (tester) async {
      final row = CollabMenuRow(title: const Text('打开'), onTap: () {});
      await _mount(tester, row, compact: compact);
      expect(tester.getSize(find.byType(CollabMenuRow)).height, compact ? 42 : 51);
      await _mount(tester, row, compact: !compact);
      expect(tester.getSize(find.byType(CollabMenuRow)).height, compact ? 51 : 42);
    });
    for (final (width, scale) in [(220.0, 1.0), (280.0, 2.2), (320.0, 2.2), (390.0, 1.5)]) {
      testWidgets('menu and switch wrap without overflow: $compact/$width/$scale', (tester) async {
        await _mount(
          tester,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CollabMenuRow(
                title: const Text('删除当前所选的内容块'),
                leading: const Icon(LucideIcons.trash2),
                trailing: const Icon(LucideIcons.check),
                onTap: () {},
              ),
              CollabSwitchRow(
                title: const Text('锁定内容块'),
                subtitle: const Text('锁状态或权限已更新，请重新打开'),
                leading: const Icon(LucideIcons.lockKeyhole),
                value: false,
                onChanged: (_) {},
              ),
            ],
          ),
          compact: compact,
          width: width,
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        final row = tester.getRect(find.byType(CollabSwitchRow));
        final control = tester.getRect(find.byType(Switch));
        expect(row.contains(control.topLeft), isTrue);
        expect(row.contains(control.bottomRight), isTrue);
        expect(row.height, greaterThanOrEqualTo(compact ? 42 : 51));
      });
    }
  }
}

/// 在 [tester] 中挂载借用 [child]，不创建业务资源。
/// [compact] 控制菜单密度，[dark] 控制亮暗主题；[width] 为逻辑宽度，
/// [scale] 为文字缩放倍率，正文可滚动以隔离外层高度约束。
Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  bool compact = false,
  bool dark = false,
  double width = 320,
  double scale = 1,
}) => tester.pumpWidget(
  MaterialApp(
    theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: CollabModalTheme(compactList: compact, child: child),
            ),
          ),
        ),
      ),
    ),
  ),
);
