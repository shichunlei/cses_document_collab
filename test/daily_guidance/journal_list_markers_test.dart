import 'dart:ui' show BoxHeightStyle;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 标记布局回归的内存草稿，不访问真实日记文件。
class _Store implements JournalStore {
  /// 最近一次自动保存的快照。
  JournalDraft? value;

  /// 返回已经保存的草稿。
  @override
  Future<JournalDraft?> read() async => value;

  /// 接收独立[draft]，供勾选保存校验。
  @override
  Future<void> write(JournalDraft draft) async {
    value = draft;
  }
}

/// 从[tester]借用当前页面的编辑器。
EditorState _state(WidgetTester tester) =>
    tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

/// 在[tester]里核对每个列表图形中心与正文第一行的实际行框中心，返回全页标记中心纵坐标。
List<double> _checkAlignment(WidgetTester tester) {
  final centers = <double>[];
  for (final node in _state(tester).document.root.children.first.children) {
    final body = tester
        .renderObjectList<RenderParagraph>(
          find.descendant(
            of: find.byKey(ValueKey('journal-lines-${node.id}')),
            matching: find.byType(RichText),
          ),
        )
        .singleWhere(
          (paragraph) =>
              paragraph.text.toPlainText() == node.delta!.toPlainText(),
        );
    final firstLine = body
        .getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: node.delta!.length),
          boxHeightStyle: BoxHeightStyle.max,
        )
        .first;
    final textCenter = body
        .localToGlobal(Offset(0, (firstLine.top + firstLine.bottom) / 2))
        .dy;
    final markerCenter = tester
        .getCenter(find.byKey(ValueKey('journal-marker-glyph-${node.id}')))
        .dy;
    expect(
      markerCenter,
      closeTo(textCenter, .1),
      reason: '${node.type}对齐第一行，不能居中于整个多行段落',
    );
    centers.add(markerCenter);
  }
  return centers;
}

/// 验证三类列表及两种待办状态在换行、缩放和预览中的对齐与原有勾选保存。
void main() {
  for (final scale in [1.0, 2.0]) {
    for (final wrap in [false, true]) {
      testWidgets(
        'list markers align with first text line at scale $scale / wrap $wrap',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(390, 1600));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final store = _Store();
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: LocalJournalPage(store: store),
            ),
          );
          await tester.pumpAndSettle();
          try {
            final state = _state(tester);
            final text = wrap ? '这是一段需要自动换行的列表正文，用于确认标记一直居中于第一行文字。' : '列表正文';
            final types = [
              TodoListBlockKeys.type,
              TodoListBlockKeys.type,
              NumberedListBlockKeys.type,
              NumberedListBlockKeys.type,
              BulletedListBlockKeys.type,
            ];
            final transaction = state.transaction;
            transaction.add(
              DeleteOperation(
                [0, 0],
                [
                  state.getNodeAtPath([0, 0])!,
                ],
              ),
              transform: false,
            );
            transaction.add(
              InsertOperation(
                [0, 0],
                [
                  for (var i = 0; i < types.length; i++)
                    Node(
                      type: types[i],
                      attributes: {
                        blockComponentDelta: (Delta()..insert('$text$i'))
                            .toJson(),
                        if (types[i] == TodoListBlockKeys.type)
                          TodoListBlockKeys.checked: i == 1,
                        if (i == 2) NumberedListBlockKeys.number: 3,
                      },
                    ),
                ],
              ),
              transform: false,
            );
            await state.apply(transaction);
            await tester.pumpAndSettle();
            expect(find.text('3.'), findsOneWidget);
            expect(find.text('4.'), findsOneWidget);
            final edit = _checkAlignment(tester);
            final first = state.getNodeAtPath([0, 0])!;
            await tester.tap(
              find.byKey(ValueKey('journal-list-marker-${first.id}')),
            );
            await tester.pump(const Duration(milliseconds: 600));
            expect(first.attributes[TodoListBlockKeys.checked], isTrue);
            expect(store.value!.documentJson, contains('"checked":true'));
            _checkAlignment(tester);
            await tester.tap(find.byKey(const ValueKey('journal-preview')));
            await tester.pumpAndSettle();
            expect(_state(tester).editable, isFalse);
            expect(_checkAlignment(tester), edit);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          }
        },
      );
    }
  }
}
