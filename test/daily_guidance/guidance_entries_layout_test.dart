import 'dart:convert';
import 'dart:ui' show BoxHeightStyle;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_entries.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_people.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_ruled_content.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 保存真实序列化草稿，供业务渲染与预览使用同一数据源。
class _Store implements JournalStore {
  /// [value] 为已验证的初始草稿，后续保存替换该快照。
  _Store(this.value);

  /// 当前草稿，不与编辑器共享节点。
  JournalDraft value;

  /// 返回当前已保存快照。
  @override
  Future<JournalDraft?> read() async => value;

  /// 替换当前快照为独立的 [draft]。
  @override
  Future<void> write(JournalDraft draft) async => value = draft;
}

/// 创建 [wrapped] 决定长短的正文和三类业务行；[longName] 为 true 时验证长名称不撑高原子对象。
JournalDraft _draft(bool wrapped, {bool longName = false}) {
  final base = JournalDraft.blank(DateTime(2026, 10, 22));
  final text = wrapped ? '这是需要自动换行的内容，用于核对人员引用和普通文字的行距一致，符号只对齐第一行。' : '甲';
  final document = Document(
    root: Node(
      type: 'page',
      children: [
        Node(
          type: journalSectionType,
          attributes: {'section': 'record'},
          children: [
            for (final kind in [null, 'task', 'help', 'pilot'])
              paragraphNode(
                delta: guidanceMentionDelta([
                  GuidancePerson(
                    id: 'u1',
                    name: longName ? List.filled(20, '张三的完整名称').join() : '张三',
                  ),
                ])..insert(text),
                attributes: {
                  if (kind != null) ...{
                    guidanceEntryAttribute: kind,
                    'guidance_entry_id': 'entry-$kind',
                    'guidance_done': false,
                  },
                },
              ),
          ],
        ),
      ],
    ),
  );
  try {
    return JournalDraft.fromJson({
      ...base.toJson(),
      'document': document.toJson(),
    });
  } finally {
    document.dispose();
  }
}

/// 从 [tester] 的实际页面获取唯一编辑器状态，预览时同样从页面读取。
EditorState _state(WidgetTester tester) =>
    tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;

/// 在 [tester] 中核对 [scale] 的首行圆环/标签、行线、选区位置及提及原子偏移。
/// [wrapped] 决定是否要求发生自动换行；返回可跨编辑/预览比较的布局快照。
List<double> _geometry(WidgetTester tester, double scale, bool wrapped) {
  final result = <double>[];
  for (final node in _state(tester).document.root.children.single.children) {
    final region = find.byKey(ValueKey('journal-lines-${node.id}'));
    final body = tester
        .renderObjectList<RenderParagraph>(
          find.descendant(of: region, matching: find.byType(RichText)),
        )
        .singleWhere(
          (paragraph) =>
              paragraph.text.toPlainText() == node.delta!.toPlainText(),
        );
    final boxes = body.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: node.delta!.length),
      boxHeightStyle: BoxHeightStyle.max,
    );
    expect(boxes, isNotEmpty);
    final first = boxes.first;
    final center = body
        .localToGlobal(Offset(0, (first.top + first.bottom) / 2))
        .dy;
    final firstHeight = first.bottom - first.top;
    expect(firstHeight, closeTo(32 * scale, .1), reason: '提及不能撑大正文行高');
    if (wrapped) {
      expect(body.size.height, greaterThan(32 * scale));
    } else {
      expect(body.size.height, closeTo(32 * scale, .1));
    }
    final kind = node.attributes[guidanceEntryAttribute];
    final Finder? marker = switch (kind) {
      'task' => find.byKey(ValueKey('guidance-task-${node.id}')),
      'help' => find.descendant(of: region, matching: find.text('都来帮')),
      'pilot' => find.descendant(of: region, matching: find.text('领航员')),
      _ => null,
    };
    if (marker != null) {
      expect(
        tester.getCenter(marker).dy,
        closeTo(center, .1),
        reason: '$kind 必须对齐首行而非整个多行段落',
      );
    }
    final rule = tester.renderObject<RenderJournalRules>(region);
    expect(
      rule.debugLineOffsets.first,
      closeTo(
        body.localToGlobal(Offset(0, first.bottom), ancestor: rule).dy,
        .1,
      ),
    );
    for (var index = 1; index < rule.debugLineOffsets.length; index++) {
      expect(
        rule.debugLineOffsets[index] - rule.debugLineOffsets[index - 1],
        closeTo(32 * scale, .1),
        reason: '每条实际行线都应维持同源正文行距',
      );
    }
    expect(node.key.currentState, isNotNull, reason: '全局节点 key 必须由原生可选段落持有');
    expect(node.selectable, isNotNull);
    final mention = body.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 1),
    );
    expect(mention, isNotEmpty, reason: '原子提及只占一个模型字符');
    final before = body.getPositionForOffset(
      Offset(
        mention.first.left,
        (mention.first.top + mention.first.bottom) / 2,
      ),
    );
    final after = body.getPositionForOffset(
      Offset(
        mention.first.right,
        (mention.first.top + mention.first.bottom) / 2,
      ),
    );
    expect(before.offset, 0);
    expect(after.offset, 1);
    result.addAll([
      body.size.width,
      body.size.height,
      firstHeight,
      center,
      ...rule.debugLineOffsets,
    ]);
  }
  return result;
}

/// 在真实今日导向页面验证原子提及、三类业务行和预览在缩放/换行下保持同源布局。
void main() {
  testWidgets('真实页面工具栏选人确认后插入、保存、预览并取消下一次选择', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = _Store(JournalDraft.blank(DateTime(2026, 10, 22)));
    await tester.pumpWidget(
      MaterialApp(
        home: LocalJournalPage(store: store, directory: const _PageDirectory()),
      ),
    );
    await tester.pumpAndSettle();
    try {
      final state = _state(tester);
      final node = state.document.root.children.single.children.single;
      await state.apply(state.transaction..insertText(node, 0, '原文'));
      state.selection = Selection.collapsed(
        Position(path: node.path, offset: 1),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guidance-action-mention')));
      await tester.pumpAndSettle();
      expect(find.text('选择用户和部门'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guidance-select-user:u1')));
      await tester.tap(
        find.byKey(const ValueKey('guidance-select-department:d1')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('guidance-people-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('选择用户和部门'), findsNothing);
      expect(find.text('人员插入失败，原文已保留，请重试'), findsNothing);
      expect(node.delta!.toPlainText(), '原\uFFFC \uFFFC 文');
      final mentions = node.delta!.whereType<TextInsert>().where(
        (op) => op.attributes?[guidanceMentionAttribute] != null,
      );
      expect(
        mentions.map((op) => readGuidanceMention(op.attributes!).identity),
        ['user:u1', 'department:d1'],
      );
      expect(find.text('@张三'), findsOneWidget);
      expect(find.text('@研发'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 600));
      final persisted = store.value.documentJson;
      expect(persisted, contains(guidanceMentionAttribute));
      await tester.tap(find.byKey(const ValueKey('guidance-action-help')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guidance-people-close')));
      await tester.pumpAndSettle();
      expect(state.document.root.children.single.children.length, 1);
      expect(node.delta!.toPlainText(), '原\uFFFC \uFFFC 文');
      await tester.tap(find.byKey(const ValueKey('journal-preview')));
      await tester.pumpAndSettle();
      expect(_state(tester).editable, isFalse);
      expect(find.text('@张三'), findsOneWidget);
      expect(find.text('@研发'), findsOneWidget);
      expect(
        _state(
          tester,
        ).document.root.children.single.children.single.delta!.toPlainText(),
        '原\uFFFC \uFFFC 文',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });

  for (final scale in [1.0, 2.0]) {
    for (final wrapped in [false, true]) {
      for (final longName in [false, if (wrapped) true]) {
        testWidgets(
          'business entry layout scale=$scale wrapped=$wrapped longName=$longName',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(390, 1800));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final store = _Store(_draft(wrapped, longName: longName));
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
              expect(tester.takeException(), isNull);
              final edit = _geometry(tester, scale, wrapped);
              final state = _state(tester);
              final task = state.document.root.children.single.children[1];
              await tester.tap(
                find.byKey(ValueKey('guidance-task-${task.id}')),
              );
              await tester.pump(const Duration(milliseconds: 600));
              expect(task.attributes['guidance_done'], isTrue);
              expect(
                jsonDecode(store.value.documentJson).toString(),
                contains('guidance_done: true'),
              );
              await tester.tap(find.byKey(const ValueKey('journal-preview')));
              await tester.pumpAndSettle();
              expect(_state(tester).editable, isFalse);
              expect(_geometry(tester, scale, wrapped), edit);
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
}

/// 注入真实页面选人入口的无网络目录，使用测试身份验证完整 UI 确认/取消链路。
class _PageDirectory implements GuidanceDirectory {
  /// 创建无资源所有权的固定测试目录。
  const _PageDirectory();

  /// 返回一个人员和一个部门，确认部门时不应展开其成员。
  @override
  Future<List<GuidancePerson>> load() async => const [
    GuidancePerson(id: 'u1', name: '张三'),
    GuidancePerson(
      id: 'd1',
      name: '研发',
      type: 'department',
      children: [GuidancePerson(id: 'u2', name: '李四')],
    ),
  ];
}
