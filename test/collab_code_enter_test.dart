import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_code_block.dart';
import 'package:cses_document_collab/src/editor/collab_code_editing.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 核对代码回车的原节点编辑、历史与实际输入连接，避免被标准段落拆分抢先处理。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final offset in [0, 2, 4]) {
    test('Enter at $offset keeps code identity and metadata', () async {
      final adapter = _adapter('代码😀');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final node = state.document.first!;
      final attributes = Map<String, dynamic>.from(node.attributes)
        ..remove(blockComponentDelta)
        ..removeWhere((key, value) => value == null);
      state.selection = Selection.single(path: [0], startOffset: offset);
      expect(await collabParagraphEnter.handler(state), isFalse);
      expect(await collabCodeEnter.handler(state), isTrue);
      expect(adapter.blocks.single.id, 'code');
      expect(adapter.blocks.single.blockType, csesCodeBlockType);
      expect(
        adapter.blocks.single.text,
        '代码😀'.replaceRange(offset, offset, '\n'),
      );
      expect(state.document.first, same(node));
      expect(
        Map<String, dynamic>.from(node.attributes)
          ..remove(blockComponentDelta)
          ..removeWhere((key, value) => value == null),
        attributes,
      );
      expect(
        state.selection,
        Selection.single(path: [0], startOffset: offset + 1),
      );
    });
  }
  test(
    'empty and repeated Enter remain in code, preserving Tab indentation',
    () async {
      final adapter = _adapter('');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      for (var i = 1; i <= 3; i++) {
        expect(await collabCodeEnter.handler(state), isTrue);
        expect(adapter.blocks.single.text, '\n' * i);
      }
      await state.insertTextAtPosition('\t\t中文');
      await collabCodeEnter.handler(state);
      expect(adapter.blocks.single.text, '\n\n\n\t\t中文\n\t\t');
      expect(state.selection!.start.offset, adapter.blocks.single.text.length);
    },
  );
  for (final reversed in [false, true]) {
    test(
      'range replacement and undo/redo are atomic, reversed=$reversed',
      () async {
        final adapter = _adapter('ab\ncd');
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        state.selection = Selection.single(
          path: [0],
          startOffset: reversed ? 4 : 1,
          endOffset: reversed ? 1 : 4,
        );
        expect(await collabCodeEnter.handler(state), isTrue);
        expect(adapter.blocks.single.text, 'a\nd');
        expect(state.selection, Selection.single(path: [0], startOffset: 2));
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.single.text, 'ab\ncd');
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.single.text, 'a\nd');
        expect(adapter.blocks.single.code!.name, '示例');
        expect(adapter.blocks.single.code!.language, 'Dart');
      },
    );
  }
  test(
    'nested code uses its own path and leaves surrounding blocks intact',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'container', blockType: 'callout', text: ''),
          CollabEditorBlock(
            id: 'code',
            parentId: 'container',
            blockType: csesCodeBlockType,
            text: 'ab',
          ),
          CollabEditorBlock(id: 'after', blockType: 'paragraph', text: '后文'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0, 0], startOffset: 1);
      expect(await collabCodeEnter.handler(state), isTrue);
      expect(adapter.blocks.map((b) => b.text), ['', 'a\nb', '后文']);
      expect(state.selection, Selection.single(path: [0, 0], startOffset: 2));
    },
  );
  test(
    'paragraph and cross-block selections fall through; readonly is unchanged',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'code',
            blockType: csesCodeBlockType,
            text: 'ab',
          ),
          CollabEditorBlock(id: 'text', blockType: 'paragraph', text: '后文'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [1], startOffset: 1);
      expect(await collabCodeEnter.handler(state), isFalse);
      state.selection = Selection(
        start: Position(path: [0], offset: 1),
        end: Position(path: [1], offset: 1),
      );
      expect(await collabCodeEnter.handler(state), isFalse);
      state.selection = Selection.single(path: [0], startOffset: 1);
      state.editable = false;
      expect(await collabCodeEnter.handler(state), isFalse);
      expect(adapter.blocks.map((b) => b.text), ['ab', '后文']);
    },
  );
  testWidgets('Shift remains available to existing input handling', (
    tester,
  ) async {
    final adapter = _adapter('ab');
    addTearDown(adapter.dispose);
    adapter.editorState.selection = Selection.single(path: [0], startOffset: 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    try {
      expect(await collabCodeEnter.handler(adapter.editorState), isFalse);
      expect(adapter.blocks.single.text, 'ab');
    } finally {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    }
  });
  testWidgets(
    'IME Enter keeps focus and continues typing in the code block',
    _verifyInput,
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }),
  );
}

/// 创建正文为 [text] 的单个代码块适配器；调用者拥有并释放适配器。
AppFlowyBlockEditorAdapter _adapter(String text) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'code',
      blockType: csesCodeBlockType,
      text: text,
      code: const CollabCode(language: 'Dart', name: '示例'),
    ),
  ],
  onLocalBlocksChanged: (_) {},
);

/// 用借用 [tester] 驱动真实输入连接，覆盖换行、选区替换和后续中文输入；在结束时释放资源。
Future<void> _verifyInput(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
        const EventChannel('keyboardHeightEventChannel'),
        MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
      );
  final adapter = _adapter('ab');
  final focus = FocusNode();
  final registerInput = !tester.testTextInput.isRegistered;
  if (registerInput) tester.testTextInput.register();
  try {
    final state = adapter.editorState;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: Scaffold(
          body: EditorShortcutToolbar(
            editorState: state,
            child: AppFlowyEditor(
              editorState: state,
              focusNode: focus,
              characterShortcutEvents: [
                collabParagraphEnter,
                collabCodeEnter,
                ...standardCharacterShortcutEvents,
              ],
              blockComponentBuilders: {
                ...standardBlockComponentBuilderMap,
                csesCodeBlockType: CollabCodeBlockComponentBuilder(),
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final selection = state.updateSelectionWithReason(
      Selection.single(path: [0], startOffset: 1),
      reason: SelectionUpdateReason.uiEvent,
    );
    await tester.pump();
    await selection;
    await tester.pump(const Duration(milliseconds: 150));
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    await _type(tester, '\n');
    expect(adapter.blocks.single.text, 'a\nb');
    await _type(tester, '\n');
    await _type(tester, '中文');
    expect(adapter.blocks.single.text, 'a\n\n中文b');
    final range = state.updateSelectionWithReason(
      Selection.single(path: [0], startOffset: 3, endOffset: 5),
      reason: SelectionUpdateReason.uiEvent,
    );
    await tester.pump();
    await range;
    await tester.pump(const Duration(milliseconds: 150));
    await _type(tester, '\n');
    expect(adapter.blocks.single.text, 'a\n\n\nb');
    expect(adapter.blocks.single.id, 'code');
    expect(adapter.blocks.single.blockType, csesCodeBlockType);
    expect(state.selection, Selection.single(path: [0], startOffset: 4));
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    adapter.dispose();
    focus.dispose();
    if (registerInput) tester.testTextInput.unregister();
    await tester.binding.setSurfaceSize(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          null,
        );
  }
}

/// 向借用 [tester] 的当前输入选区写入 [text]，保留输入连接哨兵并等待事务完成。
Future<void> _type(WidgetTester tester, String text) async {
  final editing = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  final start = editing.selection.start;
  final end = editing.selection.end;
  final value = editing.copyWith(
    text: editing.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
    composing: TextRange.empty,
  );
  // 模拟系统输入端持有最新值；编辑器无需回发完全相同的 setEditingState。
  tester.testTextInput.editingState = value.toJSON();
  tester.testTextInput.updateEditingValue(value);
  await tester.pump(const Duration(milliseconds: 200));
}
