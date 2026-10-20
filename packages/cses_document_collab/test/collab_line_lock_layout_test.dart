import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_lock_chrome.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_divider_block.dart';
import 'package:cses_document_collab/src/editor/collab_page_divider_block.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_header.dart';
import 'package:cses_document_collab/src/ui/modal/collab_switch_row.dart';

/// Exercise effective locks, titleless geometry and whole-line menu hit targets.
void main() {
  for (final kind in ['divider', 'page-divider']) {
    for (final (width, scale) in [(320.0, 1.0), (280.0, 2.2), (390.0, 1.5)]) {
      testWidgets('$kind uses a titleless lock card at $width/$scale and restores on unlock', (tester) async {
        final fixture = _fixture(kind);
        await _mount(tester, fixture.adapter, width, scale);
        final card = find.byKey(const ValueKey('line-lock-card-line'));
        expect(card, findsOneWidget);
        expect(find.byType(CollabCardHeader), findsNothing);
        expect(find.byIcon(LucideIcons.ellipsis), findsNothing);
        expect(find.byTooltip('更多操作'), findsNothing);
        final rect = tester.getRect(card);
        expect(rect.height, lessThan(75));
        final badge = find.byKey(const ValueKey('block-lock-badge-line'));
        final marker = tester.getRect(badge);
        expect(marker.top, closeTo(rect.top - 5, .01));
        expect(marker.right, closeTo(rect.right + 5, .01));
        _expectUnclipped(tester, badge);
        final before = fixture.adapter.editorState.document.toJson();
        await tester.tap(find.byKey(ValueKey('collab-$kind-line')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('block-lock-line')), findsOneWidget);
        expect(find.text('在下方插入'), findsNothing);
        expect(find.text('删除分页符'), findsNothing);
        expect(find.byKey(const ValueKey('divider-opacity')), findsNothing);
        await tester.tap(
          find.descendant(of: find.byKey(const ValueKey('block-lock-line')), matching: find.byType(Switch)),
        );
        await tester.pumpAndSettle();
        expect(card, findsNothing);
        expect(fixture.locks.state('line').locked, isFalse);
        expect(fixture.adapter.editorState.document.toJson(), before);
        expect(fixture.adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
        await tester.tap(find.byKey(ValueKey('collab-$kind-line')));
        await tester.pumpAndSettle();
        if (kind == 'divider') {
          expect(find.byKey(const ValueKey('divider-opacity')), findsOneWidget);
          await tester.tap(find.text('完成'));
        } else {
          expect(find.text('删除分页符'), findsOneWidget);
          await tester.tap(find.byTooltip('关闭').last);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
    for (final template in [false, true]) {
      testWidgets('$kind effective lock keeps card without extra badge: template=$template', (tester) async {
        final fixture = _fixture(kind, template: template, inherited: !template);
        await _mount(tester, fixture.adapter, 320, 1.5);
        expect(find.byKey(const ValueKey('line-lock-card-line')), findsOneWidget);
        expect(find.byKey(const ValueKey('block-lock-badge-line')), findsNothing);
        expect(find.byIcon(LucideIcons.ellipsis), findsNothing);
        await tester.tap(find.byKey(ValueKey('collab-$kind-line')));
        await tester.pumpAndSettle();
        expect(tester.widget<CollabSwitchRow>(find.byKey(const ValueKey('block-lock-line'))).onChanged, isNull);
        if (!template) expect(find.text('定位上级锁定块'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}

/// Build borrowed editor data for [kind]; [template]/[inherited] select authority.
/// Test teardown releases the owned lock projection before its editor adapter.
({AppFlowyBlockEditorAdapter adapter, CollabBlockLocks locks}) _fixture(
  String kind, {
  bool template = false,
  bool inherited = false,
}) {
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [
      CollabEditorBlock(
        id: 'line',
        blockType: kind,
        text: '',
        resource: kind == 'divider' ? CollabResource.fromValues({'style': 'edge-vine', 'lineColor': '#FF6B6B'}) : null,
      ),
    ],
    onLocalBlocksChanged: (_) {},
  );
  late CollabBlockLocks locks;
  locks = CollabBlockLocks(
    editor: adapter.editorState,
    userId: 'u1',
    canUnlock: (_) => false,
    commit: (_, locked, _) async => locks.update([
      CollabBlockLockState(blockId: 'line', sourceId: locked ? 'line' : null, ownerId: locked ? 'u1' : null),
    ]),
  );
  locks.update([
    CollabBlockLockState(blockId: 'line', sourceId: inherited ? 'ancestor' : 'line', ownerId: 'u1', template: template),
  ]);
  addTearDown(() {
    locks.dispose();
    adapter.dispose();
  });
  return (adapter: adapter, locks: locks);
}

/// Mount [adapter] through the production decorator on [tester]'s [width]/[scale] surface.
Future<void> _mount(WidgetTester tester, AppFlowyBlockEditorAdapter adapter, double width, double scale) async {
  await tester.binding.setSurfaceSize(Size(width, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final editor = adapter.editorState;
  editor.blockDecorator = (context, node, child) => decorateCollabBlockLock(context, editor, node, child);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: AppFlowyEditor(
            editorState: editor,
            disableKeyboardService: true,
            editorStyle: const EditorStyle.mobile(),
            blockComponentBuilders: {
              ...standardBlockComponentBuilderMap,
              'divider': CollabDividerBlockComponentBuilder(),
              'page-divider': CollabPageDividerBlockComponentBuilder(),
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Check every ancestor paint clip contains the badge [finder] mounted by [tester].
void _expectUnclipped(WidgetTester tester, Finder finder) {
  final badge = tester.getRect(finder);
  RenderObject child = tester.renderObject(finder);
  while (child.parent != null) {
    final parent = child.parent!;
    final clip = parent.describeApproximatePaintClip(child);
    if (clip != null) {
      final rect = MatrixUtils.transformRect(parent.getTransformTo(null), clip).inflate(.01);
      expect(rect.contains(badge.topLeft), isTrue, reason: '$parent clips lock');
      expect(rect.contains(badge.bottomRight), isTrue, reason: '$parent clips lock');
    }
    child = parent;
  }
}
