import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通过真实键盘链和移动工具栏注册验证列表退格；原生确认仅投影属性，不连接真实文档。
void main() {
  for (final type in [
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    for (final software in [true, false]) {
      for (final text in ['', '正文🙂']) {
        testWidgets(
          '$type software=$software text=$text keeps focus through ancestor Backspace',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(390, 844));
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockStreamHandler(
                  const EventChannel('keyboardHeightEventChannel'),
                  MockStreamHandler.inline(
                    onListen: (_, events) => events.success(0.0),
                  ),
                );
            final adapter = AppFlowyBlockEditorAdapter(
              initialBlocks: [
                const CollabEditorBlock(
                  id: 'previous',
                  blockType: 'paragraph',
                  text: '前文',
                ),
                CollabEditorBlock(
                  id: 'item',
                  blockType: type,
                  text: text,
                  indent: 3,
                  checked: type == TodoListBlockKeys.type,
                  ordered: type == NumberedListBlockKeys.type
                      ? const CollabOrdered(
                          order: 4,
                          start: 5,
                          numbering: '{"start":5,"continuePrevious":false}',
                        )
                      : null,
                ),
                const CollabEditorBlock(
                  id: 'image',
                  blockType: 'image',
                  text: '',
                  image: CollabImage(),
                ),
              ],
              onLocalBlocksChanged: (_) {},
            );
            final state = adapter.editorState;
            final focus = FocusNode();
            addTearDown(() async {
              await tester.pumpWidget(const SizedBox.shrink());
              adapter.dispose();
              focus.dispose();
              await tester.binding.setSurfaceSize(null);
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                  .setMockStreamHandler(
                    const EventChannel('keyboardHeightEventChannel'),
                    null,
                  );
            });
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
                      editorStyle: const EditorStyle.mobile(),
                      commandShortcutEvents: [
                        collabBlockBackspaceCommand,
                        ...standardCommandShortcutEvents,
                      ],
                      blockComponentBuilders: {
                        ...standardBlockComponentBuilderMap,
                        'image': CollabEmbedBlockComponentBuilder(
                          kind: CollabEmbedKind.image,
                        ),
                      },
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final selected = state.updateSelectionWithReason(
              Selection.single(path: [1], startOffset: 0),
              reason: SelectionUpdateReason.uiEvent,
            );
            await tester.pump();
            await selected;
            await tester.pump(const Duration(milliseconds: 150));
            expect(focus.hasFocus, isTrue);
            expect(tester.testTextInput.hasAnyClients, isTrue);
            final image = state.getNodeAtPath([2]);
            final item = state.getNodeAtPath([1]);
            for (final depth in [2, 1, 0, -1]) {
              if (software) {
                final current = TextEditingValue.fromJSON(
                  tester.testTextInput.editingState!,
                );
                final caret = current.selection.extentOffset;
                expect(caret, greaterThan(0)); // AppFlowy 的行首占位符提供可退格字符。
                tester.testTextInput.updateEditingValue(
                  current.copyWith(
                    text: current.text.replaceRange(caret - 1, caret, ''),
                    selection: TextSelection.collapsed(offset: caret - 1),
                    composing: TextRange.empty,
                  ),
                );
              } else {
                await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
              }
              await tester.pump(const Duration(milliseconds: 150));
              await adapter.replaceFromRemote(_projection(adapter.blocks));
              await tester.pump(const Duration(milliseconds: 150));
              expect(adapter.blocks, hasLength(3));
              expect(adapter.blocks.first.text, '前文');
              expect(
                adapter.blocks[1].blockType,
                depth < 0 ? 'paragraph' : type,
              );
              expect(adapter.blocks[1].indent, depth < 0 ? 0 : depth);
              expect(adapter.blocks[1].text, text);
              expect(
                adapter.blocks[1].checked,
                depth >= 0 && type == TodoListBlockKeys.type,
              );
              expect(state.getNodeAtPath([2]), same(image));
              if (depth >= 0) {
                expect(state.getNodeAtPath([1]), same(item));
              }
              expect(
                state.selection,
                Selection.single(path: [1], startOffset: 0),
              );
              expect(focus.hasFocus, isTrue);
              expect(tester.testTextInput.hasAnyClients, isTrue);
              expect(tester.testTextInput.isVisible, isTrue);
            }
            final current = TextEditingValue.fromJSON(
              tester.testTextInput.editingState!,
            );
            final caret = current.selection.extentOffset;
            tester.testTextInput.updateEditingValue(
              current.copyWith(
                text: current.text.replaceRange(caret, caret, '中文'),
                selection: TextSelection.collapsed(offset: caret + 2),
                composing: TextRange.empty,
              ),
            );
            await tester.pump(const Duration(milliseconds: 150));
            expect(adapter.blocks[1].text, '中文$text');
            expect(tester.takeException(), isNull);
          },
          variant: TargetPlatformVariant.only(TargetPlatform.android),
        );
      }
    }
  }
}

/// 为借用的 [blocks] 模拟属性确认，清除 replacesId 和编号写入意图；返回独立列表。
/// 保留正文、勾选和媒体字段；编号取层级制造原位属性更新，仅验证焦点，不替代原生编号测试。
List<CollabEditorBlock> _projection(List<CollabEditorBlock> blocks) => [
  for (final block in blocks)
    CollabEditorBlock(
      id: block.id,
      blockType: block.blockType,
      text: block.text,
      segments: block.segments,
      checked: block.checked,
      alignment: block.alignment,
      indent: block.indent,
      image: block.image,
      ordered: block.blockType == NumberedListBlockKeys.type
          ? CollabOrdered(
              order: block.indent,
              numbering: block.ordered!.numbering,
            )
          : null,
    ),
];
