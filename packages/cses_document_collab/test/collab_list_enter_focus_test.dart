import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/editor/collab_image_block.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用实际列表 Enter 命令验证有序/无序/Todo 列表的层级与原生投影不破坏节点身份、选区及后续输入。
/// 测试只模拟原生投影，不连接 WS 或修改业务文档。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final type in [
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    testWidgets(
      '$type Android IME stays attached through same-level Enter and ancestor exits',
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
            CollabEditorBlock(
              id: 'item',
              blockType: type,
              text: 'abcd',
              checked: type == TodoListBlockKeys.type,
              indent: 3,
              ordered: type == NumberedListBlockKeys.type
                  ? const CollabOrdered(order: 0)
                  : null,
            ),
            CollabEditorBlock(
              id: 'image',
              blockType: 'image',
              text: '',
              image: CollabImage(),
            ),
          ],
          onLocalBlocksChanged: (_) {},
        );
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
              body: AppFlowyEditor(
                editorState: state,
                focusNode: focus,
                editorStyle: const EditorStyle.mobile(),
                characterShortcutEvents: [
                  collabListEnter,
                  ...standardCharacterShortcutEvents,
                ],
                blockComponentBuilders: {
                  ...standardBlockComponentBuilderMap,
                  'image': CollabImageBlockComponentBuilder(),
                },
              ),
            ),
          ),
        );
        await tester.pump();
        final selectionUpdate = state.updateSelectionWithReason(
          Selection.single(path: [0], startOffset: 4),
          reason: SelectionUpdateReason.uiEvent,
        );
        await tester.pump();
        await selectionUpdate;
        await tester.pump(const Duration(milliseconds: 150));
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);

        // 通过实际输入连接发送换行，经过 AppFlowy IME 和列表快捷键处理。
        final editing = TextEditingValue.fromJSON(
          tester.testTextInput.editingState!,
        );
        final offset = editing.selection.extentOffset;
        tester.testTextInput.updateEditingValue(
          editing.copyWith(
            text: editing.text.replaceRange(offset, offset, '\n'),
            selection: TextSelection.collapsed(offset: offset + 1),
            composing: TextRange.empty,
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect(state.selection, Selection.single(path: [1], startOffset: 0));
        final newNode = state.getNodeAtPath([1]);
        await adapter.replaceFromRemote(_numberedProjection(adapter.blocks));
        await tester.pump(const Duration(milliseconds: 150));
        expect(state.getNodeAtPath([1]), same(newNode));
        expect(state.selection, Selection.single(path: [1], startOffset: 0));
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(adapter.blocks[1].indent, 3);
        expect(adapter.blocks[0].checked, type == TodoListBlockKeys.type);
        expect(adapter.blocks[1].checked, isFalse);
        for (final depth in [2, 1, 0, -1]) {
          final current = TextEditingValue.fromJSON(
            tester.testTextInput.editingState!,
          );
          final offset = current.selection.extentOffset;
          tester.testTextInput.updateEditingValue(
            current.copyWith(
              text: current.text.replaceRange(offset, offset, '\n'),
              selection: TextSelection.collapsed(offset: offset + 1),
              composing: TextRange.empty,
            ),
          );
          await tester.pump(const Duration(milliseconds: 150));
          await adapter.replaceFromRemote(_numberedProjection(adapter.blocks));
          await tester.pump(const Duration(milliseconds: 150));
          expect(adapter.blocks, hasLength(3));
          expect(adapter.blocks[1].blockType, depth < 0 ? 'paragraph' : type);
          expect(adapter.blocks[1].indent, depth < 0 ? 0 : depth);
          expect(state.selection, Selection.single(path: [1], startOffset: 0));
          expect(focus.hasFocus, isTrue);
          expect(tester.testTextInput.hasAnyClients, isTrue);
        }
        final after = TextEditingValue.fromJSON(
          tester.testTextInput.editingState!,
        );
        final caret = after.selection.extentOffset;
        tester.testTextInput.updateEditingValue(
          after.copyWith(
            text: after.text.replaceRange(caret, caret, '中文'),
            selection: TextSelection.collapsed(offset: caret + 2),
            composing: TextRange.empty,
          ),
        );
        await tester.pump(const Duration(milliseconds: 150));
        expect(adapter.blocks[1].text, '中文');
        final imageNode = state.document.root.children.last;
        await adapter.replaceFromRemote([
          ...adapter.blocks.take(2),
          const CollabEditorBlock(
            id: 'image',
            blockType: 'image',
            text: '',
            image: CollabImage(
              widthRatio: 30,
              captions: [CollabImageCaption(id: 'caption', text: '更新题注')],
            ),
          ),
        ]);
        await tester.pump(const Duration(milliseconds: 150));
        expect(state.document.root.children.last, same(imageNode));
        expect(find.text('更新题注'), findsOneWidget);
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
  for (final offset in [0, 2, 4]) {
    test(
      'mixed media list Enter at $offset retains caret after numbering',
      () async {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = _mixedAdapter('abcd', changes);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        state.selection = Selection.single(path: [1], startOffset: offset);
        expect(await insertNewLineAfterNumberedList.handler(state), isTrue);
        final nodes = List<Node>.of(state.document.root.children);
        final selection = state.selection;
        final localCount = changes.length;
        final undoItem = state.undoManager.undoStack.last;
        final undoCount = undoItem.operations.length;

        await adapter.replaceFromRemote(_numberedProjection(adapter.blocks));

        expect(state.selection, selection);
        for (var i = 0; i < nodes.length; i++) {
          expect(state.document.root.children[i], same(nodes[i]));
        }
        expect(changes, hasLength(localCount));
        expect(state.undoManager.undoStack.last, same(undoItem));
        expect(undoItem.operations, hasLength(undoCount));
        await state.insertTextAtPosition('中文');
        expect(adapter.blocks[2].text, '中文${'abcd'.substring(offset)}');
        expect(adapter.blocks.last.image!.captions.single.text, '题注');
        expect(changes.last[2].ordered!.numberingEdit, isNull);
      },
    );
  }

  test(
    'empty list exit keeps paragraph caret after canonical acknowledgement',
    () async {
      final adapter = _mixedAdapter('', []);
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [1], startOffset: 0);
      expect(await insertNewLineAfterNumberedList.handler(state), isTrue);
      final node = state.getNodeAtPath([1]);
      final selection = state.selection;
      expect(node!.type, ParagraphBlockKeys.type);
      await adapter.replaceFromRemote(_numberedProjection(adapter.blocks));
      expect(state.selection, selection);
      expect(state.getNodeAtPath([1]), same(node));
      await state.insertTextAtPosition('继续输入');
      expect(adapter.blocks[1].text, '继续输入');
    },
  );

  test('repeated Enter and undo redo keep mixed document editable', () async {
    final adapter = _mixedAdapter('abcd', []);
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    state.selection = Selection.single(path: [1], startOffset: 4);
    for (var i = 0; i < 3; i++) {
      await insertNewLineAfterNumberedList.handler(state);
      await adapter.replaceFromRemote(_numberedProjection(adapter.blocks));
      expect(state.selection, Selection.single(path: [2 + i], startOffset: 0));
      await state.insertTextAtPosition('item$i');
      await adapter.replaceFromRemote(_numberedProjection(adapter.blocks));
    }
    state.undoManager.undo();
    await Future<void>.delayed(Duration.zero);
    await adapter.replaceFromRemote(_numberedProjection(adapter.blocks));
    state.undoManager.redo();
    await Future<void>.delayed(Duration.zero);
    await adapter.replaceFromRemote(_numberedProjection(adapter.blocks));
    expect(adapter.blocks[4].text, 'item2');
    await state.insertTextAtPosition('!');
    expect(adapter.blocks[4].text, 'item2!');
    expect(adapter.blocks.last.id, 'image');
  });

  test(
    'media attribute patches preserve text nodes and clear removed image projection',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = _mixedAdapter('abcd', changes);
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      final nodes = List<Node>.of(state.document.root.children);
      final selection = Selection.single(path: [1], startOffset: 2);
      state.selection = selection;
      final target = adapter.blocks
          .map(
            (block) => _copyProjection(
              block,
              text: block.blockType == 'numbered_list'
                  ? null
                  : 'https://example.com/new',
              clearImage: true,
            ),
          )
          .toList();
      await adapter.replaceFromRemote(target);
      expect(state.selection, selection);
      for (var i = 0; i < nodes.length; i++) {
        expect(state.document.root.children[i], same(nodes[i]));
      }
      expect(adapter.blocks, target);
      expect(
        state.document.root.children.last.attributes[collabImageAttribute],
        isNull,
      );
      expect(changes, isEmpty);
    },
  );
}

/// 创建带图片、列表、视频、链接、正式图片的离线适配器；[text] 是列表正文，
/// [changes] 接收本地事务快照。调用方持有并负责 dispose，不创建网络资源。
AppFlowyBlockEditorAdapter _mixedAdapter(
  String text,
  List<List<CollabEditorBlock>> changes,
) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    const CollabEditorBlock(
      id: 'leading-image',
      blockType: ImageBlockKeys.type,
      text: '',
    ),
    CollabEditorBlock(
      id: 'list',
      blockType: 'numbered_list',
      text: text,
      ordered: const CollabOrdered(order: 0),
    ),
    const CollabEditorBlock(
      id: 'video',
      blockType: csesVideoBlockType,
      text: 'https://example.com/video',
    ),
    const CollabEditorBlock(
      id: 'link',
      blockType: csesLinkBlockType,
      text: 'https://example.com/link',
    ),
    const CollabEditorBlock(
      id: 'image',
      blockType: 'image',
      text: '',
      image: CollabImage(
        widthRatio: 60,
        captions: [CollabImageCaption(id: 'caption', text: '题注')],
      ),
    ),
  ],
  onLocalBlocksChanged: changes.add,
);

/// 为 [blocks] 模拟 Rust 同一事务返回的零基编号及替换确认；保留正文、格式及媒体字段，
/// 不生成 numberingEdit，返回新列表且不修改输入集合。
List<CollabEditorBlock> _numberedProjection(List<CollabEditorBlock> blocks) {
  var order = 0;
  return blocks
      .map(
        (block) => _copyProjection(
          block,
          ordered: block.blockType == 'numbered_list'
              ? CollabOrdered(order: order++)
              : null,
        ),
      )
      .toList();
}

/// 复制 [block] 并清除本地 replacesId；[text] 为 null 时保留正文，
/// [ordered] 为 null 时保留编号，[clearImage] 控制是否移除正式图片投影，默认保留。
/// 返回独立不可变块，不执行编辑器事务或持有资源。
CollabEditorBlock _copyProjection(
  CollabEditorBlock block, {
  String? text,
  CollabOrdered? ordered,
  bool clearImage = false,
}) => CollabEditorBlock(
  id: block.id,
  blockType: block.blockType,
  text: text ?? block.text,
  segments: block.segments,
  checked: block.checked,
  alignment: block.alignment,
  indent: block.indent,
  image: clearImage ? null : block.image,
  ordered: ordered ?? block.ordered,
);
