import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 注册工具栏与添加面板的事务、光标恢复和权限回归；测试各自释放借用的编辑器。
void main() {
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
    'empty paragraph converts to a heading and preserves block id',
    () async {
      final state = _editorState(text: '');
      addTearDown(state.dispose);
      final selection = Selection.single(path: [0], startOffset: 0);

      final applied = await applyBlockShortcut(
        state,
        selection,
        HeadingBlockKeys.type,
        headingLevel: 6,
      );

      expect(applied, isTrue);
      final node = state.document.first!;
      expect(node.type, HeadingBlockKeys.type);
      expect(node.attributes[HeadingBlockKeys.level], 6);
      expect(node.attributes['cses_collab_block_id'], 'block-a');
    },
  );

  test('non-empty paragraph inserts a new list block after it', () async {
    final state = _editorState(text: 'existing');
    addTearDown(state.dispose);
    final selection = Selection.single(path: [0], startOffset: 3);

    final applied = await applyBlockShortcut(
      state,
      selection,
      BulletedListBlockKeys.type,
    );

    expect(applied, isTrue);
    expect(state.document.root.children, hasLength(2));
    expect(state.document.root.children.first.type, ParagraphBlockKeys.type);
    expect(state.document.root.children.last.type, BulletedListBlockKeys.type);
    expect(state.selection?.start.path, [1]);
  });

  test('empty paragraph converts to an unchecked todo block', () async {
    final state = _editorState(text: '');
    addTearDown(state.dispose);

    final applied = await applyBlockShortcut(
      state,
      Selection.single(path: [0], startOffset: 0),
      TodoListBlockKeys.type,
    );

    expect(applied, isTrue);
    expect(state.document.first!.type, TodoListBlockKeys.type);
    expect(
      state.document.first!.attributes[TodoListBlockKeys.checked],
      isFalse,
    );
    expect(state.document.first!.attributes['cses_collab_block_id'], 'block-a');
  });

  test(
    'URL-backed blocks leave an editable paragraph caret after insertion',
    () async {
      for (final blockType in const [
        ImageBlockKeys.type,
        csesLinkBlockType,
        csesVideoBlockType,
      ]) {
        final state = _editorState(text: '');
        addTearDown(state.dispose);

        final nextSelection = await applyUrlBlockShortcut(
          state,
          Selection.single(path: [0], startOffset: 0),
          blockType,
          'https://example.com/resource',
        );

        // A non-text resource cannot own the IME selection. The function
        // returns the trailing paragraph caret, while the transaction leaves
        // selection null so a still-visible modal cannot open the keyboard
        // prematurely; the outer UI restores this caret after dismissal.
        expect(nextSelection?.start.path, [1]);
        expect(state.document.root.children, hasLength(2));
        expect(state.document.root.children.first.type, blockType);
        expect(state.document.root.children.last.type, ParagraphBlockKeys.type);
        expect(state.selection, isNull);
      }
    },
  );

  test('URL-backed insertion rejects unsafe or incomplete URLs', () async {
    final state = _editorState(text: 'existing');
    addTearDown(state.dispose);

    final nextSelection = await applyUrlBlockShortcut(
      state,
      Selection.single(path: [0], startOffset: 1),
      csesLinkBlockType,
      'javascript:alert(1)',
    );

    expect(nextSelection, isNull);
    expect(state.document.root.children, hasLength(1));
  });

  testWidgets(
    'more directly creates a 2x2 table without a dialog and undo removes it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final state = _editorState(text: '原文');
      state.selection = Selection.single(path: [0], startOffset: 1);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(_toolbarApp(state));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('editor-shortcut-table'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      // 等待添加面板退场后的360ms键盘恢复窗口。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('editor-add-block-sheet')),
        findsNothing,
      );
      expect(state.document.first!.delta!.toPlainText(), '原文');
      final table = state.document.root.children[1];
      expect(table.type, 'table');
      expect(table.children.length, 2);
      expect(table.children.first.children.length, 2);
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(state.document.root.children.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('plus toolbar exposes H1 through H9 and applies H9', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: '');
    state.selection = Selection.single(path: [0], startOffset: 0);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      tester.view.resetViewInsets();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();

    expect(find.byKey(const ValueKey('editor-shortcut-add')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('editor-add-block-sheet')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('editor-shortcut-add')),
      findsNothing,
      reason: 'the keyboard toolbar follows the dismissed keyboard',
    );
    expect(tester.takeException(), isNull);
    // The add sheet is the non-progressive entry point, so both ends of the
    // supported H1-H9 range must exist immediately.
    expect(
      find.byKey(const ValueKey('editor-shortcut-heading-1')),
      findsOneWidget,
    );
    final headingList = find.byKey(const ValueKey('editor-add-heading-list'));
    expect(headingList, findsOneWidget);
    // H1-H9 remain on one horizontal axis. Reveal H9 with a horizontal gesture
    // before looking it up because ListView lazily builds off-screen children.
    await tester.drag(headingList, const Offset(-360, 0));
    await tester.pumpAndSettle();
    final headingNine = find.byKey(const ValueKey('editor-shortcut-heading-9'));
    expect(headingNine, findsOneWidget);
    await tester.tap(headingNine);
    await tester.pumpAndSettle();
    // Advance beyond the Android-only fallback window so the test observes
    // the same settled IME state as a device after the bottom sheet closes.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(state.document.first!.type, HeadingBlockKeys.type);
    expect(state.document.first!.attributes[HeadingBlockKeys.level], 9);
    expect(find.byKey(const ValueKey('editor-add-block-sheet')), findsNothing);
    // Choosing a block returns the resulting caret to the editor instead of
    // treating the sheet dismissal as a cancellation.
    expect(state.selection?.start.path, [0]);
    expect(state.selection?.start.offset, 0);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsOneWidget);
    expect(
      state.selectionExtraInfo?[selectionExtraInfoDisableMobileToolbarKey],
      isNot(true),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('plus sheet inserts a link URL and restores the trailing caret', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'Existing paragraph');
    state.selection = Selection.single(path: [0], startOffset: 8);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
    await tester.pumpAndSettle();

    final linkTile = find.byKey(const ValueKey('editor-shortcut-link-block'));
    await tester.ensureVisible(linkTile);
    await tester.tap(linkTile);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('editor-link-source-sheet')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('editor-url-block-input')),
      'https://example.com/article',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
    await tester.pumpAndSettle();
    // The production flow retries a cancelled Android IME animation once.
    // Pump that bounded delay to ensure no retry timer leaks past teardown.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // The source paragraph remains, followed by the resource and an editable
    // paragraph that receives the restored keyboard selection.
    expect(state.document.root.children, hasLength(3));
    expect(state.document.root.children[1].type, csesLinkBlockType);
    expect(
      state.document.root.children[1].attributes[csesEmbedUrlAttribute],
      'https://example.com/article',
    );
    expect(state.document.root.children[2].type, ParagraphBlockKeys.type);
    expect(state.selection?.start.path, [2]);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plus selection focuses an inserted block after existing text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'Existing paragraph');
    state.selection = Selection.single(path: [0], startOffset: 8);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
    await tester.pumpAndSettle();

    // Choosing a block after non-empty text follows the insertion path. The
    // returned caret must point at the new empty block, not the source block or
    // null, so AppFlowy's keyboard service can attach to an editable location.
    final quote = find.byKey(const ValueKey('editor-shortcut-quote'));
    await tester.ensureVisible(quote);
    await tester.tap(quote);
    await tester.pumpAndSettle();
    // Settle the guarded Android IME retry used after modal route dismissal.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(state.document.root.children, hasLength(2));
    expect(state.document.root.children.last.type, QuoteBlockKeys.type);
    expect(state.selection?.start.path, [1]);
    expect(state.selection?.start.offset, 0);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final sourceText in ['', 'Existing paragraph']) {
    testWidgets(
      'plus sheet inserts code from ${sourceText.isEmpty ? 'empty' : 'non-empty'} text and restores its caret',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        final state = _editorState(text: sourceText);
        state.selection = Selection.single(path: [0], startOffset: 0);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          state.dispose();
          await tester.binding.setSurfaceSize(null);
        });

        await tester.pumpWidget(_toolbarApp(state));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
        await tester.pumpAndSettle();
        final code = find.byKey(const ValueKey('editor-shortcut-code-block'));
        await tester.ensureVisible(code);
        await tester.tap(code);
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        final codeIndex = sourceText.isEmpty ? 0 : 1;
        expect(state.document.root.children, hasLength(codeIndex + 1));
        final codeNode = state.document.root.children[codeIndex];
        expect(codeNode.type, csesCodeBlockType);
        expect(codeNode.delta!.toPlainText(), isEmpty);
        if (sourceText.isEmpty) {
          expect(codeNode.attributes['cses_collab_block_id'], 'block-a');
        } else {
          expect(state.document.first!.delta!.toPlainText(), sourceText);
          expect(state.document.first!.type, ParagraphBlockKeys.type);
        }
        expect(state.selection?.start.path, [codeIndex]);
        expect(state.selection?.start.offset, 0);
        expect(
          find.byKey(const ValueKey('editor-add-block-sheet')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('editor-mobile-toolbar')),
          findsOneWidget,
        );
        expect(find.textContaining('尚未进入当前'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('plus code entry follows its source after a remote insertion', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'Original paragraph');
    state.selection = Selection.single(path: [0], startOffset: 4);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
    await tester.pumpAndSettle();
    await state.apply(
      state.transaction
        ..insertNode([0], paragraphNode(text: 'Remote paragraph')),
      options: const ApplyOptions(recordUndo: false, inMemoryUpdate: true),
    );
    await tester.pump();
    final code = find.byKey(const ValueKey('editor-shortcut-code-block'));
    await tester.ensureVisible(code);
    await tester.tap(code);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(state.document.root.children, hasLength(3));
    expect(
      state.document.root.children[0].delta!.toPlainText(),
      'Remote paragraph',
    );
    expect(
      state.document.root.children[1].delta!.toPlainText(),
      'Original paragraph',
    );
    expect(state.document.root.children[2].type, csesCodeBlockType);
    expect(state.selection?.start.path, [2]);
    expect(find.byKey(const ValueKey('editor-add-block-sheet')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'plus code entry rejects permission revoked while the sheet is open',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final state = _editorState(text: 'Original paragraph');
      state.selection = Selection.single(path: [0], startOffset: 0);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(_toolbarApp(state));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
      await tester.pumpAndSettle();
      state.editable = false;
      final code = find.byKey(const ValueKey('editor-shortcut-code-block'));
      await tester.ensureVisible(code);
      await tester.tap(code);
      await tester.pumpAndSettle();

      expect(state.document.root.children, hasLength(1));
      expect(state.document.first!.type, ParagraphBlockKeys.type);
      expect(state.document.first!.delta!.toPlainText(), 'Original paragraph');
      expect(
        find.byKey(const ValueKey('editor-add-block-sheet')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('H menu converts the selected block to todo', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'task');
    state.selection = Selection.single(path: [0], startOffset: 2);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();

    expect(find.byKey(const ValueKey('editor-shortcut-task')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();
    final todo = find.byKey(const ValueKey('editor-block-todo_list-0'));
    await tester.ensureVisible(todo);
    await tester.tap(todo);
    await tester.pumpAndSettle();

    expect(state.document.first!.type, TodoListBlockKeys.type);
    expect(
      state.document.first!.attributes[TodoListBlockKeys.checked],
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('menus stay above and close together with the keyboard', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'Hello');
    state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      tester.view.resetViewInsets();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state, keyboardInset: 300));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-inline-style')),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('editor-inline-style-menu')),
      findsOneWidget,
    );
    expect(state.selection, isNotNull);

    await tester.tap(find.byKey(const ValueKey('editor-inline-bold')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-inline-strikethrough')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsOneWidget);
    expect(state.selection, isNotNull);
    final attributes = state.document.first!.delta!.first.attributes!;
    expect(attributes[AppFlowyRichTextKeys.bold], isTrue);
    expect(attributes[AppFlowyRichTextKeys.strikethrough], isTrue);

    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('editor-inline-style-menu')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('editor-block-style-menu')),
      findsOneWidget,
    );
    expect(state.selection, isNotNull);

    await tester.tap(find.byKey(const ValueKey('editor-block-heading-1')));
    await tester.pumpAndSettle();

    expect(state.document.first!.type, HeadingBlockKeys.type);
    expect(state.document.first!.attributes[HeadingBlockKeys.level], 1);
    expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsOneWidget);
    expect(state.selection, isNotNull);

    await tester.pumpWidget(_toolbarApp(state, keyboardInset: 0));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsNothing);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsNothing);
    expect(state.selection, isNotNull);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-toolbar-popup')), findsNothing);
    expect(state.selection, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('typing and newline keep the editor toolbar active', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'Hello');
    state.selection = Selection.single(path: [0], startOffset: 5);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state, keyboardInset: 300));
    await tester.pump();

    final node = state.document.first!;
    final transaction = state.transaction
      ..insertText(node, 5, '!', toggledAttributes: state.toggledStyle)
      ..afterSelection = Selection.single(path: [0], startOffset: 6);
    await state.apply(transaction);
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.selection?.start.path, [0]);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsOneWidget);

    await state.insertNewLine();
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.selection?.start.path, [1]);
    expect(state.selection?.start.offset, 0);
    expect(find.byKey(const ValueKey('editor-mobile-toolbar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tapping a middle empty paragraph requests the Android keyboard',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final state = EditorState(
        document: Document(
          root: Node(
            type: 'page',
            children: [
              paragraphNode(text: 'before'),
              paragraphNode(text: ''),
              paragraphNode(text: 'after'),
            ],
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        await tester.binding.setSurfaceSize(null);
      });

      await tester.pumpWidget(_toolbarApp(state, keyboardInset: 0));
      await tester.pump();
      tester.testTextInput.hide();
      expect(tester.testTextInput.isVisible, isFalse);

      final selectionUpdate = state.updateSelectionWithReason(
        Selection.single(path: [1], startOffset: 0),
        reason: SelectionUpdateReason.uiEvent,
      );
      // `updateSelectionWithReason` and the workaround both synchronize at a
      // frame boundary. Pump once to complete selection delivery, then advance
      // past the guarded 100 ms window used to avoid duplicate normal requests.
      await tester.pump();
      await selectionUpdate;
      await tester.pump(const Duration(milliseconds: 120));

      expect(tester.testTextInput.isVisible, isTrue);
      expect(state.selection?.start.path, [1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Aa owns color and H owns all block-list actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'Hello');
    state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 5);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('editor-shortcut-list-style')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('editor-shortcut-task')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-inline-style')),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('editor-inline-bold')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('editor-inline-text-color')),
      findsOneWidget,
    );
    expect(find.text('加粗'), findsNothing);
    expect(find.text('删除线'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('editor-inline-text-color')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('editor-text-color-menu')),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const ValueKey('editor-text-color-menu')),
      const Offset(-220, 0),
    );
    await tester.pumpAndSettle();
    final blue = find.byKey(const ValueKey('editor-text-color-blue'));
    await tester.tap(blue);
    await tester.pumpAndSettle();
    expect(
      state.document.first!.delta!.first.attributes?[AppFlowyRichTextKeys
          .textColor],
      '0xff2196f3',
    );
    await tester.drag(
      find.byKey(const ValueKey('editor-text-color-menu')),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-text-color-back')));
    await tester.pump();
    final colorIcon = tester.widget<Icon>(
      find.byKey(const ValueKey('editor-inline-text-color-icon')),
    );
    expect(colorIcon.color, const Color(0xFF2196F3));

    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('editor-block-numbered_list-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('editor-block-bulleted_list-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('editor-block-todo_list-0')),
      findsOneWidget,
    );
    expect(find.text('有序列表'), findsNothing);
    expect(find.text('无序列表'), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('editor-block-style-menu')),
      const Offset(-260, 0),
    );
    await tester.pumpAndSettle();
    final codeBlock = find.byKey(const ValueKey('editor-block-code-0'));
    expect(codeBlock, findsOneWidget);
    expect(find.byKey(const ValueKey('editor-block-quote-0')), findsOneWidget);
    await tester.tap(codeBlock);
    await tester.pumpAndSettle();
    expect(state.document.first!.type, 'code');
    expect(tester.takeException(), isNull);
  });

  testWidgets('primary T progressively reveals H4 through H9 and resets', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'Heading', secondText: 'Second');
    state.selection = Selection.single(path: [0], startOffset: 3);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();

    expect(find.text('T'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('editor-block-heading-3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('editor-block-heading-4')), findsNothing);

    // Selecting H3 reveals H4. Reopening T while the caret remains in H3 must
    // derive that same H3/H4 range from the document rather than hiding H4.
    await tester.tap(find.byKey(const ValueKey('editor-block-heading-3')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('editor-block-heading-4')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();
    expect(find.byKey(const ValueKey('editor-block-style-menu')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('editor-block-heading-4')),
      findsOneWidget,
    );

    // A still-open menu must also reset when the caret enters another block.
    await tester.tap(find.byKey(const ValueKey('editor-block-heading-3')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('editor-block-heading-4')),
      findsOneWidget,
    );
    state.selection = Selection.single(path: [1], startOffset: 2);
    await tester.pump();
    expect(find.byKey(const ValueKey('editor-block-heading-4')), findsNothing);
    state.selection = Selection.single(path: [0], startOffset: 3);
    await tester.pump();

    for (var level = 3; level <= 8; level += 1) {
      final heading = find.byKey(ValueKey('editor-block-heading-$level'));
      await tester.ensureVisible(heading);
      await tester.tap(heading);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('editor-block-heading-${level + 1}')),
        findsOneWidget,
      );
    }
    final headingNine = find.byKey(const ValueKey('editor-block-heading-9'));
    expect(headingNine, findsOneWidget);
    await tester.ensureVisible(headingNine);
    await tester.tap(headingNine);
    await tester.pumpAndSettle();
    expect(state.document.first!.attributes[HeadingBlockKeys.level], 9);

    await tester.drag(
      find.byKey(const ValueKey('editor-block-style-menu')),
      const Offset(1200, 0),
    );
    await tester.pumpAndSettle();
    final paragraph = find.byKey(const ValueKey('editor-block-paragraph-0'));
    await tester.tap(paragraph);
    await tester.pumpAndSettle();

    expect(state.document.first!.type, ParagraphBlockKeys.type);
    expect(
      find.byKey(const ValueKey('editor-block-heading-3')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('editor-block-heading-4')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('T reveals a deep current heading and its next level', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(
      text: 'Paragraph',
      secondText: 'Deep heading',
      secondBlockType: HeadingBlockKeys.type,
      secondHeadingLevel: 4,
    );
    state.selection = Selection.single(path: [0], startOffset: 3);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();

    // A paragraph begins with the compact H1-H3 set.
    expect(find.byKey(const ValueKey('editor-block-heading-4')), findsNothing);

    // Moving into H4 while T remains open must reveal both the current H4 and
    // the next progressive choice H5, but no level beyond H5.
    state.selection = Selection.single(path: [1], startOffset: 4);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('editor-block-heading-4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('editor-block-heading-5')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('editor-block-heading-6')), findsNothing);

    // Closing and reopening T on the same H4 block derives the same range from
    // the document instead of falling back to H1-H3.
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-block-style')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('editor-block-heading-4')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('editor-block-heading-5')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Aa applies and displays an inline background color', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'Highlight');
    state.selection = Selection.single(path: [0], startOffset: 0, endOffset: 9);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-inline-style')),
    );
    await tester.pump();
    // The Aa row is intentionally horizontally scrollable on a 390 px phone.
    // Move the newly inserted background entry fully into the hit-test area
    // before exercising it, matching the gesture a user performs on-device.
    await tester.drag(
      find.byKey(const ValueKey('editor-inline-style-menu')),
      const Offset(-120, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('editor-inline-background-color')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('editor-background-color-menu')),
      findsOneWidget,
    );
    await tester.drag(
      find.byKey(const ValueKey('editor-background-color-menu')),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('editor-background-color-yellow')),
    );
    await tester.pumpAndSettle();

    expect(
      state.document.first!.delta!.first.attributes?[AppFlowyRichTextKeys
          .backgroundColor],
      '0x4dffc107',
    );
    await tester.drag(
      find.byKey(const ValueKey('editor-background-color-menu')),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('editor-background-color-back')),
    );
    await tester.pump();
    final backgroundIcon = tester.widget<Icon>(
      find.byKey(const ValueKey('editor-inline-background-color-icon')),
    );
    expect(backgroundIcon.color, const Color(0x4DFFC107));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Aa menu applies mutually exclusive superscript and subscript', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'x2');
    state.selection = Selection.single(path: [0], startOffset: 1, endOffset: 2);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-inline-style')),
    );
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('editor-inline-style-menu')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    final superscript = find.byKey(const ValueKey('editor-inline-superscript'));
    await tester.tap(superscript);
    await tester.pumpAndSettle();
    expect(
      state.document.first!.delta!.last.attributes?[csesSuperscriptAttribute],
      isTrue,
    );

    final subscript = find.byKey(const ValueKey('editor-inline-subscript'));
    await tester.tap(subscript);
    await tester.pumpAndSettle();
    final attributes = state.document.first!.delta!.last.attributes!;
    expect(attributes[csesSuperscriptAttribute], isNull);
    expect(attributes[csesSubscriptAttribute], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline style persists until manual toggle or paragraph switch', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'x', secondText: 'next');
    state.selection = Selection.single(path: [0], startOffset: 1);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-inline-style')),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('editor-inline-style-menu')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-inline-superscript')));
    await tester.pumpAndSettle();

    expect(state.toggledStyle[csesSuperscriptAttribute], isTrue);
    expect(
      state.toggledStyle.keys.every(
        AppFlowyRichTextKeys.supportToggled.contains,
      ),
      isTrue,
    );

    final node = state.document.first!;
    final transaction = state.transaction
      ..insertText(node, 1, '2', toggledAttributes: state.toggledStyle)
      ..afterSelection = Selection.single(path: [0], startOffset: 2);
    await state.apply(transaction);
    await tester.pump(const Duration(milliseconds: 100));
    expect(node.delta!.last.attributes?[csesSuperscriptAttribute], isTrue);
    expect(state.toggledStyle[csesSuperscriptAttribute], isTrue);

    final nextTransaction = state.transaction
      ..insertText(node, 2, '3', toggledAttributes: state.toggledStyle)
      ..afterSelection = Selection.single(path: [0], startOffset: 3);
    await state.apply(nextTransaction);
    await tester.pump(const Duration(milliseconds: 100));
    expect(node.delta!.toPlainText(), 'x23');
    expect(node.delta!.last.attributes?[csesSuperscriptAttribute], isTrue);
    expect(state.toggledStyle[csesSuperscriptAttribute], isTrue);

    await tester.tap(find.byKey(const ValueKey('editor-inline-superscript')));
    await tester.pumpAndSettle();
    expect(state.toggledStyle[csesSuperscriptAttribute], isNull);

    await tester.tap(find.byKey(const ValueKey('editor-inline-superscript')));
    await tester.pumpAndSettle();
    expect(state.toggledStyle[csesSuperscriptAttribute], isTrue);

    state.selection = Selection.single(path: [1], startOffset: 0);
    await tester.pump();
    expect(state.toggledStyle[csesSuperscriptAttribute], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('entering a paragraph initializes Aa from caret formatting', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(text: 'styled', secondText: 'plain');
    final styledNode = state.document.first!;
    final transaction = state.transaction
      ..formatText(styledNode, 0, 6, {
        AppFlowyRichTextKeys.bold: true,
        AppFlowyRichTextKeys.textColor: '0xff2196f3',
        AppFlowyRichTextKeys.backgroundColor: '0x4dffc107',
      });
    await state.apply(transaction);
    // AppFlowy seals an undo history item with a 50 ms debounce. Advance the
    // widget-test clock so that setup work cannot leave a pending fake timer.
    await tester.pump(const Duration(milliseconds: 60));

    // The caret sits exactly at the end of the styled run. Initialization must
    // use the character on its left so typing can naturally continue the run.
    state.selection = Selection.single(path: [0], startOffset: 6);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();

    expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
    expect(state.toggledStyle[AppFlowyRichTextKeys.textColor], '0xff2196f3');
    expect(
      state.toggledStyle[AppFlowyRichTextKeys.backgroundColor],
      '0x4dffc107',
    );

    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-inline-style')),
    );
    await tester.pump();
    expect(
      tester
          .widget<Icon>(
            find.byKey(const ValueKey('editor-inline-text-color-icon')),
          )
          .color,
      const Color(0xFF2196F3),
    );
    expect(
      tester
          .widget<Icon>(
            find.byKey(const ValueKey('editor-inline-background-color-icon')),
          )
          .color,
      const Color(0x4DFFC107),
    );

    // Switching to an unformatted paragraph must clear both the Aa state and
    // AppFlowy's upcoming-input attributes. Returning initializes them again.
    state.selection = Selection.single(path: [1], startOffset: 1);
    await tester.pump();
    expect(state.toggledStyle, isEmpty);

    state.selection = Selection.single(path: [0], startOffset: 6);
    await tester.pump();
    expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
    expect(
      state.toggledStyle[AppFlowyRichTextKeys.backgroundColor],
      '0x4dffc107',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'quote colors change independently and can be cleared and undone',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 844));
      final state = _editorState(text: '引用正文', blockType: QuoteBlockKeys.type);
      state.selection = Selection.single(path: [0], startOffset: 2);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(_toolbarApp(state));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('editor-shortcut-block-layout')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('editor-block-border-color')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('editor-block-border-color-red')),
      );
      await tester.pumpAndSettle();
      final node = state.document.first!;
      final border = node.attributes[csesBlockBorderColorAttribute];
      expect(border, contains('244, 67, 54'));
      expect(state.selection?.startIndex, 2);
      await tester.tap(
        find.byKey(const ValueKey('editor-block-border-color-back')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('editor-block-background-color')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('editor-block-background-color-yellow')),
      );
      await tester.pumpAndSettle();
      final background = node.attributes[csesBlockBackgroundColorAttribute];
      expect(background, contains('255, 193, 7'));
      expect(node.attributes[csesBlockBorderColorAttribute], border);
      expect(node.delta!.toPlainText(), '引用正文');
      expect(
        node.delta!.first.attributes?[AppFlowyRichTextKeys.backgroundColor],
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('editor-block-background-color-default')),
      );
      await tester.pumpAndSettle();
      expect(node.attributes[csesBlockBackgroundColorAttribute], isNull);
      state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(node.attributes[csesBlockBackgroundColorAttribute], background);
      expect(node.attributes[csesBlockBorderColorAttribute], border);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('block layout supports justify and distributed with undo', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 844));
    final state = _editorState(text: '两端对齐和分散对齐');
    state.selection = Selection.single(path: [0], startOffset: 3);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-block-layout')),
    );
    await tester.pump();
    for (final mode in ['justify', 'distributed']) {
      await tester.tap(find.byKey(ValueKey('editor-block-align-$mode')));
      await tester.pumpAndSettle();
      expect(state.document.first!.attributes[blockComponentAlign], mode);
      expect(state.selection?.startIndex, 3);
    }
    state.undoManager.undo();
    await tester.pumpAndSettle();
    expect(state.document.first!.attributes[blockComponentAlign], 'justify');
    state.undoManager.redo();
    await tester.pumpAndSettle();
    expect(
      state.document.first!.attributes[blockComponentAlign],
      'distributed',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('block layout menu aligns and indents list blocks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final state = _editorState(
      text: 'nested item',
      blockType: NumberedListBlockKeys.type,
    );
    state.selection = Selection.single(path: [0], startOffset: 3);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
      await tester.binding.setSurfaceSize(null);
    });

    await tester.pumpWidget(_toolbarApp(state));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-block-layout')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('editor-block-layout-menu')),
      findsOneWidget,
    );
    expect(find.text('左对齐'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('editor-block-align-center')));
    await tester.pumpAndSettle();
    expect(state.document.first!.attributes[blockComponentAlign], 'center');

    await tester.tap(find.byKey(const ValueKey('editor-block-indent')));
    await tester.pumpAndSettle();
    expect(state.document.first!.attributes[csesBlockIndentAttribute], 1);

    await tester.tap(find.byKey(const ValueKey('editor-block-outdent')));
    await tester.pumpAndSettle();
    expect(state.document.first!.attributes[csesBlockIndentAttribute], 0);
    expect(tester.takeException(), isNull);
  });
}

Widget _toolbarApp(EditorState state, {double keyboardInset = 300}) {
  return MaterialApp(
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      AppFlowyEditorLocalizations.delegate,
    ],
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(
          viewInsets: EdgeInsets.only(bottom: keyboardInset),
        ),
        child: EditorShortcutToolbar(
          editorState: state,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    ),
  );
}

EditorState _editorState({
  required String text,
  String blockType = ParagraphBlockKeys.type,
  int headingLevel = 1,
  String? secondText,
  String secondBlockType = ParagraphBlockKeys.type,
  int secondHeadingLevel = 1,
}) {
  return EditorState(
    document: Document(
      root: Node(
        type: 'page',
        children: [
          Node(
            type: blockType,
            id: 'block-a',
            attributes: {
              blockComponentDelta: (Delta()..insert(text)).toJson(),
              'cses_collab_block_id': 'block-a',
              if (blockType == HeadingBlockKeys.type)
                HeadingBlockKeys.level: headingLevel.clamp(1, 9),
              if (blockType == TodoListBlockKeys.type)
                TodoListBlockKeys.checked: false,
            },
          ),
          if (secondText != null)
            Node(
              type: secondBlockType,
              id: 'block-b',
              attributes: {
                blockComponentDelta: (Delta()..insert(secondText)).toJson(),
                'cses_collab_block_id': 'block-b',
                if (secondBlockType == HeadingBlockKeys.type)
                  HeadingBlockKeys.level: secondHeadingLevel.clamp(1, 9),
                if (secondBlockType == TodoListBlockKeys.type)
                  TodoListBlockKeys.checked: false,
              },
            ),
        ],
      ),
    ),
  );
}
