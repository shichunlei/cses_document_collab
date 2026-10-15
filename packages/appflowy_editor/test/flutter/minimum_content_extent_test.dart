import 'package:appflowy_editor/src/flutter/scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies minimum document extent independently of the trailing footer and indexed navigation.
void main() {
  /// Renders [count] indexed items of [itemHeight] with a 200-pixel footer after a 600-pixel minimum.
  /// [controller] supplies borrowed indexed navigation; [onBuild] observes lazy item creation.
  Widget buildList({
    int count = 2,
    double itemHeight = 40,
    ItemScrollController? controller,
    void Function(int)? onBuild,
  }) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          key: const ValueKey('viewport'),
          height: 600,
          child: ScrollablePositionedList.builder(
            itemCount: count,
            itemScrollController: controller,
            minimumContentExtent: 600,
            footer: const SizedBox(key: ValueKey('footer'), height: 200),
            itemBuilder: (_, index) {
              onBuild?.call(index);
              return SizedBox(key: ValueKey('item-$index'), height: itemHeight);
            },
          ),
        ),
      ),
    ),
  );

  testWidgets('empty body still reserves a viewport before the footer', (
    tester,
  ) async {
    await tester.pumpWidget(buildList(count: 0));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('footer'))).dy,
      closeTo(
        tester.getBottomLeft(find.byKey(const ValueKey('viewport'))).dy,
        0.1,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('short body fills a viewport and footer scrolls to its bottom', (
    tester,
  ) async {
    await tester.pumpWidget(buildList());
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byKey(const ValueKey('viewport')));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('footer'))).dy,
      closeTo(viewport.bottom, 0.1),
    );
    await tester.drag(
      find.byType(ScrollablePositionedList),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('footer'))).dy,
      closeTo(viewport.bottom, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('index jump includes content before the anchor in the minimum', (
    tester,
  ) async {
    final controller = ItemScrollController();
    await tester.pumpWidget(buildList(controller: controller));
    await tester.pumpAndSettle();
    controller.jumpTo(index: 1);
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(find.byKey(const ValueKey('item-1'))).dy;
    final footer = tester.getTopLeft(find.byKey(const ValueKey('footer'))).dy;
    expect(footer - first, closeTo(560, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('long body remains lazy and has no gap before its footer', (
    tester,
  ) async {
    final built = <int>{};
    final controller = ItemScrollController();
    await tester.pumpWidget(
      buildList(
        count: 1000,
        itemHeight: 100,
        controller: controller,
        onBuild: built.add,
      ),
    );
    await tester.pumpAndSettle();
    expect(built.length, lessThan(50));
    controller.jumpTo(index: 999);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('footer'))).dy,
      closeTo(
        tester.getBottomLeft(find.byKey(const ValueKey('item-999'))).dy,
        0.1,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
