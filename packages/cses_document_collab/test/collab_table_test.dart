import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_table_block.dart';
import 'package:cses_document_collab/src/editor/collab_table_row_block.dart';
import 'package:cses_document_collab/src/editor/collab_table_cell_block.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证表格真实父子结构、正文历史、远端重排与窄屏滚动。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });

  test(
    'cell edits and undo preserve parents; table structure commands are atomic',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(),
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final table = state.document.first!;
      final cell = table.children.first.children.first;
      final body = cell.children.first;
      expect(body.path, [0, 0, 0, 0]);
      state.selection = Selection.single(path: body.path, startOffset: 0);
      expect(isProtectedCalloutBoundary(state), isTrue);
      await state.apply(state.transaction..insertText(body, 2, '编辑'));
      expect(changes.single.firstWhere((b) => b.id == 'p0').parentId, 'c0');
      expect(changes.single.firstWhere((b) => b.id == 'p0').text, '正文编辑0');
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.firstWhere((b) => b.id == 'p0').text, '正文0');
      state.undoManager.redo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.firstWhere((b) => b.id == 'p0').text, '正文编辑0');
      final fingerprint = collabTableFingerprint(table);
      expect(
        await applyCollabTableEdit(
          state,
          't',
          fingerprint,
          CollabTableAction.insertColumn,
          row: 0,
          column: 1,
        ),
        isTrue,
      );
      expect(state.document.first!.children.first.children.length, 4);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(state.document.first!.children.first.children.length, 3);
      final restoredCell = state.document.first!.children.first.children.first;
      await state.apply(
        state.transaction
          ..insertNode(restoredCell.path + [1], paragraphNode(text: '第二段')),
      );
      expect(changes.last.last.parentId, 'c2');
      expect(
        changes.last
            .where((b) => b.parentId == 'c0')
            .map((b) => '${b.id}:${b.blockType}:${b.text}')
            .toList(),
        ['p0:paragraph:正文编辑0', isA<String>()],
      );
    },
  );

  test(
    'remote layout patches preserve cell node and active selection',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final body = state.document.nodeAtPath([0, 0, 0, 0])!;
      state.selection = Selection.single(path: body.path, startOffset: 1);
      final next = _blocks(width: 220);
      await adapter.replaceFromRemote(next);
      expect(state.document.nodeAtPath([0, 0, 0, 0]), same(body));
      expect(state.selection!.start.offset, 1);
      expect(adapter.blocks.first.resource!.values['colWidths'], [
        220,
        220,
        220,
      ]);
    },
  );

  test(
    'remote table body changes invalidate path history without echo',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(),
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final body = state.document.nodeAtPath([0, 0, 0, 0])!;
      await state.apply(state.transaction..insertText(body, 0, '手机'));
      expect(state.undoManager.undoStack.isNonEmpty, isTrue);
      final next = _blocks();
      next[3] = const CollabEditorBlock(
        id: 'p0',
        blockType: 'paragraph',
        text: '远端最新',
        parentId: 'c0',
      );
      await adapter.replaceFromRemote(next);
      expect(state.undoManager.undoStack.isEmpty, isTrue);
      expect(state.undoManager.redoStack.isEmpty, isTrue);
      expect(state.selection, isNull);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks[3].text, '远端最新');
      expect(changes.length, 1);
    },
  );

  test(
    'merged geometry survives row/column insertion and deleting the original master row',
    () {
      final table = createCollabTable(3, 3);
      final source = table.children[0].children[0];
      source.children.first.updateAttributes({
        'delta': (Delta()..insert('保留内容')).toJson(),
      });
      var next = buildCollabTableEdit(
        table,
        CollabTableAction.merge,
        row: 0,
        column: 0,
        endRow: 1,
        endColumn: 1,
      )!;
      expect(collabTableRegions(next).length, 6);
      expect(collabTableSpan(next.children[0].children[0], 'rowspan'), 2);
      next = buildCollabTableEdit(
        next,
        CollabTableAction.insertRow,
        row: 1,
        column: 0,
      )!;
      expect(collabTableSpan(next.children[0].children[0], 'rowspan'), 3);
      next = buildCollabTableEdit(
        next,
        CollabTableAction.insertColumn,
        row: 0,
        column: 1,
      )!;
      expect(collabTableSpan(next.children[0].children[0], 'colspan'), 3);
      next = buildCollabTableEdit(
        next,
        CollabTableAction.deleteRow,
        row: 0,
        column: 0,
      )!;
      expect(
        collabTableNodeId(next.children[0].children[0]),
        collabTableNodeId(source),
      );
      expect(
        next.children[0].children[0].children.first.delta!.toPlainText(),
        '保留内容',
      );
      expect(collabTableSpan(next.children[0].children[0], 'rowspan'), 2);
      next = buildCollabTableEdit(
        next,
        CollabTableAction.split,
        row: 0,
        column: 0,
      )!;
      expect(collabTableRegions(next).length, 12);
      expect(
        next.children[0].children[0].children.first.delta!.toPlainText(),
        '保留内容',
      );
      expect(
        collabTableLayout(next.children[1].children[1])['display'],
        isNull,
      );
    },
  );

  test(
    'merge expands across existing spans and size/permission/stale limits reject without changes',
    () async {
      var table = createCollabTable(3, 3);
      table = buildCollabTableEdit(
        table,
        CollabTableAction.merge,
        row: 0,
        column: 1,
        endRow: 1,
        endColumn: 2,
      )!;
      table = buildCollabTableEdit(
        table,
        CollabTableAction.merge,
        row: 1,
        column: 0,
        endRow: 2,
        endColumn: 1,
      )!;
      expect(collabTableRegions(table).length, 1);
      expect(collabTableSpan(table.children[0].children[0], 'rowspan'), 3);
      expect(
        buildCollabTableEdit(
          createCollabTable(1, 1),
          CollabTableAction.deleteRow,
          row: 0,
          column: 0,
        ),
        isNull,
      );
      expect(
        buildCollabTableEdit(
          createCollabTable(10, 50),
          CollabTableAction.insertRow,
          row: 0,
          column: 0,
        ),
        isNull,
      );
      expect(
        buildCollabTableEdit(
          table,
          CollabTableAction.resizeColumn,
          row: 0,
          column: 0,
          width: 0,
        ),
        isNull,
      );
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final fingerprint = collabTableFingerprint(state.document.first!);
      final body = state.document.nodeAtPath([0, 0, 0, 0])!;
      await state.apply(state.transaction..insertText(body, 0, '新'));
      expect(
        await applyCollabTableEdit(
          state,
          't',
          fingerprint,
          CollabTableAction.insertRow,
          row: 0,
          column: 0,
        ),
        isFalse,
      );
      state.editable = false;
      expect(
        await applyCollabTableEdit(
          state,
          't',
          collabTableFingerprint(state.document.first!),
          CollabTableAction.insertRow,
          row: 0,
          column: 0,
        ),
        isFalse,
      );
    },
  );

  testWidgets('tapping body resolves through unrendered table rows', (
    tester,
  ) async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: _blocks(),
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    await _pumpTableEditor(tester, adapter);
    expect(find.byKey(const ValueKey('block-more-t')), findsNothing);
    expect(find.byTooltip('更多操作'), findsNothing);
    final table = adapter.editorState.document.first!;
    expect(table.children.first.key.currentContext, isNull);
    expect(table.children.first.rect.isEmpty, isFalse);
    for (var column = 0; column < 2; column++) {
      final body = table.children.first.children[column].children.first;
      await tester.tapAt(body.rect.topLeft + const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(adapter.editorState.selection?.start.path, body.path);
    }
    expect(tester.takeException(), isNull);
  });

  for (final editable in [true, false]) {
    testWidgets(
      '2x2 table aligns with left content edge preview=${!editable}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: _blocks(width: 120, rows: 2),
          onLocalBlocksChanged: (_) {},
        );
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        await applyCollabTableEdit(
          state,
          't',
          collabTableFingerprint(state.document.first!),
          CollabTableAction.deleteColumn,
          row: 0,
          column: 2,
        );
        await _pumpTableEditor(tester, adapter, editable: editable);
        final cell = find.byKey(const ValueKey('collab-table-cell-c0'));
        expect(tester.getTopLeft(cell).dx, closeTo(20, 0.01));
        if (editable) {
          await _activateTable(tester, adapter);
          expect(
            tester
                .getTopLeft(find.byKey(const ValueKey('table-row-header-0')))
                .dx,
            closeTo(20, 0.01),
          );
          expect(tester.getTopLeft(cell).dx, closeTo(44, 0.01));
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('table edge controls are hidden until clicked and hide outside', (
    tester,
  ) async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: _blocks(),
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    await _pumpTableEditor(tester, adapter);
    final header = find.byKey(const ValueKey('table-column-header-0'));
    expect(header, findsNothing);
    await _activateTable(tester, adapter);
    expect(header, findsOneWidget);
    await tester.tapAt(const Offset(2, 550));
    await tester.pumpAndSettle();
    expect(header, findsNothing);
    await _activateTable(tester, adapter);
    await tester.tap(header);
    await tester.pumpAndSettle();
    await tester.tap(find.text('插入列'));
    await tester.pumpAndSettle();
    expect(header, findsOneWidget);
    expect(find.text('向左插入列'), findsOneWidget);
    Navigator.of(tester.element(find.text('向左插入列'))).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'edge menus insert before/after and delete rows and columns atomically',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(rows: 2),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _pumpTableEditor(tester, adapter);
      await _activateTable(tester, adapter);
      final state = adapter.editorState;
      for (final column in [true, false]) {
        final original = column ? 3 : 2;
        for (final after in [false, true]) {
          await _activateTable(tester, adapter);
          await tester.tap(
            find.byKey(ValueKey('table-${column ? 'column' : 'row'}-header-0')),
          );
          await tester.pumpAndSettle();
          expect(state.selection, isNull);
          await tester.tap(find.text(column ? '插入列' : '插入行'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.text(
              column
                  ? (after ? '向右插入列' : '向左插入列')
                  : (after ? '向下插入行' : '向上插入行'),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            column
                ? state.document.first!.children.first.children.length
                : state.document.first!.children.length,
            original + 1,
          );
          state.undoManager.undo();
          await tester.pumpAndSettle();
          expect(
            column
                ? state.document.first!.children.first.children.length
                : state.document.first!.children.length,
            original,
          );
        }
        await _activateTable(tester, adapter);
        await tester.tap(
          find.byKey(ValueKey('table-${column ? 'column' : 'row'}-header-0')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(column ? '删除列' : '删除行'));
        await tester.pumpAndSettle();
        expect(
          column
              ? state.document.first!.children.first.children.length
              : state.document.first!.children.length,
          original - 1,
        );
        state.undoManager.undo();
        await tester.pumpAndSettle();
        expect(
          state.document.nodeAtPath([0, 0, 0, 0])!.delta!.toPlainText(),
          '正文0',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('edge menus disable deletion of the last row and column', (
    tester,
  ) async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: _blocks(),
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    for (var i = 0; i < 2; i++) {
      await applyCollabTableEdit(
        state,
        't',
        collabTableFingerprint(state.document.first!),
        CollabTableAction.deleteColumn,
        row: 0,
        column: 1,
      );
    }
    await _pumpTableEditor(tester, adapter);
    await _activateTable(tester, adapter);
    for (final axis in ['row', 'column']) {
      await tester.tap(find.byKey(ValueKey('table-$axis-header-0')));
      await tester.pumpAndSettle();
      final label = axis == 'row' ? '删除行' : '删除列';
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed,
        isNull,
      );
      Navigator.of(tester.element(find.text(label))).pop();
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'column boundary previews locally and saves once on release with undo',
    (tester) async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(),
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await _pumpTableEditor(tester, adapter);
      await _activateTable(tester, adapter);
      final before =
          collabTableLayout(adapter.editorState.document.first!)['colWidths']
              as List;
      final initial = (before.first as num).toDouble();
      final handle = find.byKey(const ValueKey('table-column-resize-0'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(70, 0));
      await tester.pump();
      expect(changes, isEmpty);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('collab-table-cell-c0')))
            .width,
        greaterThan(initial),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, hasLength(1));
      expect(
        (collabTableLayout(adapter.editorState.document.first!)['colWidths']
                as List)
            .first,
        greaterThan(initial),
      );
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(
        (collabTableLayout(adapter.editorState.document.first!)['colWidths']
                as List)
            .first,
        initial,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('remote change cancels an in-flight width drag', (tester) async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: _blocks(),
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    await _pumpTableEditor(tester, adapter);
    await _activateTable(tester, adapter);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('table-column-resize-0'))),
    );
    await gesture.moveBy(const Offset(25, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    await adapter.replaceFromRemote(_blocks(width: 220));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(
      (collabTableLayout(adapter.editorState.document.first!)['colWidths']
              as List)
          .first,
      220,
    );
    expect(tester.takeException(), isNull);
  });

  for (final revoke in [true, false]) {
    testWidgets(
      'edge menu stays invalid after permission or content changes revoke=$revoke',
      (tester) async {
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: _blocks(),
          onLocalBlocksChanged: (_) {},
        );
        addTearDown(adapter.dispose);
        await _pumpTableEditor(tester, adapter);
        await _activateTable(tester, adapter);
        await tester.tap(find.byKey(const ValueKey('table-column-header-0')));
        await tester.pumpAndSettle();
        if (revoke) {
          adapter.editorState.editable = false;
          adapter.editorState.editable = true;
        } else {
          await adapter.replaceFromRemote(_blocks(width: 220));
        }
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '删除列'))
              .onPressed,
          isNull,
        );
        Navigator.of(tester.element(find.text('删除列'))).pop();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'merged cell spans rows/columns and more sheet only offers merge and split at 320px',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(rows: 3),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      expect(
        await applyCollabTableEdit(
          state,
          't',
          collabTableFingerprint(state.document.first!),
          CollabTableAction.merge,
          row: 0,
          column: 0,
          endRow: 1,
          endColumn: 1,
        ),
        isTrue,
      );
      await _pumpTableEditor(tester, adapter);
      expect(tester.takeException(), isNull);
      final master = find.byKey(const ValueKey('collab-table-cell-c0'));
      expect(tester.getSize(master).width, 320);
      expect(tester.getSize(master).height, greaterThanOrEqualTo(120));
      expect(find.byKey(const ValueKey('collab-table-cell-c1')), findsNothing);
      expect(find.byKey(const ValueKey('collab-table-cell-c3')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('table-cell-options-c0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-cell-options-c0')));
      await tester.pumpAndSettle();
      expect(find.text('在下方插入'), findsNothing);
      final split = find.text('拆分单元格');
      await tester.ensureVisible(split);
      await tester.tap(split);
      await tester.pumpAndSettle();
      expect(collabTableRegions(state.document.first!).length, 9);
      expect(
        find.byKey(const ValueKey('collab-table-cell-c1')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('table-cell-options-c0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-cell-options-c0')));
      await tester.pumpAndSettle();
      for (final label in [
        '上方插入行',
        '下方插入行',
        '删除当前行',
        '左侧插入列',
        '右侧插入列',
        '删除当前列',
        '应用列宽',
      ]) {
        expect(find.text(label), findsNothing);
      }
      expect(find.byType(Slider), findsNothing);
      expect(find.text('合并所选区域'), findsOneWidget);
      expect(find.text('拆分单元格'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'a local write immediately after synchronous remote replay is published',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(),
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final next = _blocks(width: 220);
      final replay = adapter.replaceFromRemote(next);
      final state = adapter.editorState;
      final body = state.document.nodeAtPath([0, 0, 0, 0])!;
      await state.apply(state.transaction..insertText(body, 0, '即时'));
      await replay;
      expect(changes.length, 1);
      expect(adapter.blocks.firstWhere((b) => b.id == 'p0').text, '即时正文0');
    },
  );

  test(
    'a permission revocation during remote completion remains revoked',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final replay = adapter.replaceFromRemote(_blocks(width: 220));
      adapter.editorState.editable = false;
      await replay;
      expect(adapter.editorState.editable, isFalse);
    },
  );

  for (final revoke in [true, false]) {
    testWidgets(
      'open table sheet rejects permission/remote changes revoke=$revoke',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: _blocks(),
          onLocalBlocksChanged: (_) {},
        );
        addTearDown(adapter.dispose);
        await _pumpTableEditor(tester, adapter);
        await tester.tap(find.byKey(const ValueKey('table-cell-options-c0')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('table-merge-end-column')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第2列').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '合并所选区域'),
              )
              .onPressed,
          isNotNull,
        );
        if (revoke) {
          adapter.editorState.editable = false;
        } else {
          await adapter.replaceFromRemote(_blocks(width: 220));
        }
        await tester.pumpAndSettle();
        final button = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, '合并所选区域'),
        );
        expect(button.onPressed, isNull);
        if (revoke) {
          adapter.editorState.editable = true;
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '合并所选区域'),
                )
                .onPressed,
            isNull,
          );
        }
        expect(find.text('表格或权限已更新，请关闭后重新打开'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
        expect(adapter.editorState.document.first!.children.length, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final editable in [true, false]) {
    testWidgets(
      '320px table scrolls horizontally, preserves body and preview=$editable',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 568));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: _blocks(),
          onLocalBlocksChanged: (_) {},
        );
        addTearDown(adapter.dispose);
        await _pumpTableEditor(tester, adapter, editable: editable);
        expect(
          find.byKey(const ValueKey('collab-table-cell-c0')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('table-column-header-0')),
          findsNothing,
        );
        if (editable) {
          adapter.editorState.selection = Selection.single(
            path: [0, 0, 0, 0],
            startOffset: 3,
          );
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: '正文0输入',
              selection: TextSelection.collapsed(offset: 5),
            ),
          );
          await tester.pumpAndSettle();
          expect(adapter.blocks[3].text, '正文0输入');
        }
        final last = find.byKey(const ValueKey('collab-table-cell-c2'));
        final before = tester.getTopLeft(last).dx;
        final scroll = find.byKey(const PageStorageKey('collab-table-t'));
        await tester.drag(scroll, const Offset(-240, 0));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(last).dx, lessThan(before));
        expect(tester.takeException(), isNull);
        expect(
          adapter.blocks
              .where((b) => b.blockType == 'paragraph')
              .map((b) => b.text),
          [editable ? '正文0输入' : '正文0', '正文1', '正文2'],
        );
      },
    );
  }
}

/// 返回[rows]行三列的合成前序树；[width]为桌面列宽逻辑像素，默认一行。
List<CollabEditorBlock> _blocks({int width = 160, int rows = 1}) => [
  CollabEditorBlock(
    id: 't',
    blockType: 'table',
    text: '',
    resource: CollabResource.fromValues({
      'colWidths': [width, width, width],
    }),
  ),
  for (var r = 0; r < rows; r++) ...[
    CollabEditorBlock(
      id: r == 0 ? 'r' : 'r$r',
      blockType: 'table-row',
      text: '',
      parentId: 't',
      resource: const CollabResource(properties: '{"height":60}'),
    ),
    for (var c = 0; c < 3; c++) ...[
      CollabEditorBlock(
        id: 'c${r * 3 + c}',
        blockType: 'table-cell',
        text: '',
        parentId: r == 0 ? 'r' : 'r$r',
        resource: const CollabResource(properties: '{"verticalAlign":"top"}'),
      ),
      CollabEditorBlock(
        id: 'p${r * 3 + c}',
        blockType: 'paragraph',
        text: '正文${r * 3 + c}',
        parentId: 'c${r * 3 + c}',
      ),
    ],
  ],
];

/// 将借用[adapter]挂载到真实输入/滚动服务；[tester]负责生命周期，[editable]控制预览。
Future<void> _pumpTableEditor(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter, {
  bool editable = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(
        body: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(1.5),
          ),
          child: AppFlowyEditor(
            editorState: adapter.editorState,
            editable: editable,
            disableKeyboardService: !editable,
            editorStyle: const EditorStyle.mobile(
              padding: EdgeInsets.symmetric(horizontal: 20),
            ),
            blockComponentBuilders: {
              ...standardBlockComponentBuilderMap,
              'table': CollabTableBlockComponentBuilder(),
              'table-row': CollabTableRowBlockComponentBuilder(),
              'table-cell': CollabTableCellBlockComponentBuilder(),
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 点击借用[adapter]首格正文并等待[tester]布局，激活表格边缘操作条。
Future<void> _activateTable(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter,
) async {
  final body = adapter
      .editorState
      .document
      .first!
      .children
      .first
      .children
      .first
      .children
      .first;
  await tester.tapAt(body.rect.topLeft + const Offset(8, 8));
  await tester.pumpAndSettle();
}
