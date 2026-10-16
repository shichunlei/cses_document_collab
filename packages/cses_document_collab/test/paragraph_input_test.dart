import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_presentation.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通过真实输入连接核对空段落样式、下一段规则及键盘持续输入。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android paragraph defaults and soft keyboard Enter',
    verifyMobileParagraphInput,
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

/// 用借用 [tester] 驱动输入连接；创建并释放编辑器/焦点，供 Widget 与真机集成测试复用。
Future<void> verifyMobileParagraphInput(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
        const EventChannel('keyboardHeightEventChannel'),
        MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
      );
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [
      CollabEditorBlock(
        id: 'heading',
        blockType: 'heading_2',
        text: '',
        paragraphStyle: CollabResource.fromValues({
          'nextParagraphStyle': 'same',
          'textDefaults': {'a:bold': true, 't:px': 24, 't:ff': 'courier'},
        }),
      ),
    ],
    onLocalBlocksChanged: (_) {},
  );
  final focus = FocusNode();
  final registerInput = !tester.testTextInput.isRegistered;
  if (registerInput) tester.testTextInput.register();
  try {
    final state = adapter.editorState;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: const EdgeInsets.only(bottom: 300)),
          child: child!,
        ),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: EditorShortcutToolbar(
            editorState: state,
            child: AppFlowyEditor(
              editorState: state,
              focusNode: focus,
              editorStyle: EditorStyle.mobile(
                textSpanDecorator:
                    (context, node, index, text, before, after) =>
                        after.copyWith(
                          style: collabParagraphTextStyle(
                            node,
                            after.style ?? const TextStyle(),
                            text.attributes ?? {},
                            applyParagraph: false,
                          ),
                        ),
              ),
              characterShortcutEvents: [
                collabParagraphEnter,
                ...standardCharacterShortcutEvents,
              ],
              blockComponentBuilders: {
                for (final entry in standardBlockComponentBuilderMap.entries)
                  entry.key:
                      const {
                        ParagraphBlockKeys.type,
                        HeadingBlockKeys.type,
                        QuoteBlockKeys.type,
                        BulletedListBlockKeys.type,
                        NumberedListBlockKeys.type,
                        TodoListBlockKeys.type,
                      }.contains(entry.key)
                      ? configureCollabParagraphPresentation(
                          entry.value,
                          entry.key,
                        )
                      : entry.value,
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final selected = state.updateSelectionWithReason(
      Selection.single(path: [0], startOffset: 0),
      reason: SelectionUpdateReason.uiEvent,
    );
    await tester.pump();
    await selected;
    await tester.pump(const Duration(milliseconds: 150));
    expect(focus.hasFocus, isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(state.toggledStyle['t:px'], 24);
    await _type(tester, '中文');
    expect(adapter.blocks.single.segments.single.bold, isTrue);
    expect(adapter.blocks.single.segments.single.typography, contains('24'));
    await _type(tester, '\n');
    expect(adapter.blocks, hasLength(2));
    expect(adapter.blocks.last.blockType, 'heading_2');
    expect(
      adapter.blocks.last.paragraphStyle!.values['textDefaults'],
      containsPair('t:px', 24),
    );
    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-block-layout')),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('editor-block-layout-menu')),
      const Offset(-1200, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-next-paragraph-body')));
    await tester.pumpAndSettle();
    expect(
      adapter.blocks.last.paragraphStyle!.values['nextParagraphStyle'],
      'body',
    );
    await tester.tap(
      find.byKey(const ValueKey('editor-shortcut-block-layout')),
    );
    await tester.pump();
    await _type(tester, '\n');
    expect(adapter.blocks, hasLength(2));
    expect(adapter.blocks.last.blockType, 'paragraph');
    expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isNull);
    await _type(tester, '正文');
    expect(adapter.blocks.last.text, '正文');
    expect(adapter.blocks.last.segments, isEmpty);
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

/// 向借用 [tester] 当前输入连接发送 [text]，保留输入框前后哨兵并等待编辑事务。
Future<void> _type(WidgetTester tester, String text) async {
  final editing = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
  final offset = editing.selection.extentOffset;
  tester.testTextInput.updateEditingValue(
    editing.copyWith(
      text: editing.text.replaceRange(offset, offset, text),
      selection: TextSelection.collapsed(offset: offset + text.length),
      composing: TextRange.empty,
    ),
  );
  await tester.pump(const Duration(milliseconds: 200));
}
