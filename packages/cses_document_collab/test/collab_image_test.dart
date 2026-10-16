import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/editor/collab_image_content.dart';
import 'package:cses_document_collab/src/editor/collab_image_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 创建独立图片投影；[image] 为专属布局，[url] 默认其他端 blob，用于无网络 Widget 测试。
CollabEditorBlock _block(
  CollabImage image, {
  String url = 'blob:fixture-upload',
}) => CollabEditorBlock(
  id: 'image-1',
  blockType: ImageBlockKeys.type,
  text: url,
  alignment: 'right',
  image: image,
);

/// 测试布局、节点属性、事务、迟到表单和只读行为，不连接真实 WS 或图片服务器。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const image = CollabImage(
    widthRatio: 60,
    aspectRatio: 1.5,
    rotation: 15,
    captions: [CollabImageCaption(id: 'caption-1', text: '图片题注😀')],
  );

  test(
    'ratio layout has priority and legacy sizes scale without writing defaults',
    () {
      expect(image.resolveSize(300), (180.0, 120.0));
      expect(const CollabImage(width: 600, height: 200).resolveSize(300), (
        300.0,
        100.0,
      ));
      expect(
        const CollabImage(
          widthRatio: 50,
          aspectRatio: 2,
          width: 600,
          height: 200,
        ).resolveSize(300),
        (150.0, 75.0),
      );
      expect(const CollabImage().resolveSize(300), (300.0, 225.0));
      expect(const CollabImage(widthRatio: 200).resolveSize(300), (
        300.0,
        225.0,
      ));
      expect(
        const CollabImage(
          widthRatio: double.nan,
          aspectRatio: 0,
        ).resolveSize(300),
        (300.0, 225.0),
      );
      expect(const CollabImage().widthRatio, isNull);
    },
  );

  test(
    'node map uses exact keys and restores immutable caption identities',
    () {
      expect(image.toJson(), {
        'wr': 60.0,
        'ar': 1.5,
        'width': null,
        'height': null,
        'rotation': 15.0,
        'captions': [
          {'id': 'caption-1', 'text': '图片题注😀'},
        ],
      });
      final restored = CollabImage.fromJson(image.toJson());
      expect(restored, image);
      expect(() => restored.captions.clear(), throwsUnsupportedError);
      expect(CollabImage.fromJson({'wr': 60, 'ar': 2}).widthRatio, 60.0);
    },
  );

  test(
    'remote size and caption changes refresh one image projection without local echo',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_block(image)],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      expect(adapter.blocks.single.image, image);
      expect(
        adapter.editorState.document.root.children.single.children,
        isEmpty,
      );
      const replaced = CollabImage(
        widthRatio: 30,
        aspectRatio: 2,
        captions: [CollabImageCaption(id: 'caption-1', text: '远端题注')],
      );
      await adapter.replaceFromRemote([
        _block(replaced, url: 'https://example.test/new.png'),
      ]);
      expect(adapter.blocks.single.image, replaced);
      expect(adapter.blocks.single.text, 'https://example.test/new.png');
      expect(changes, isEmpty);
    },
  );

  test(
    'form changes merge with unrelated remote fields and reject same-field conflict',
    () async {
      final original = _block(image);
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [original],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      adapter.editorState.editable = true;
      final remote = _block(
        CollabImage(
          widthRatio: 30,
          aspectRatio: image.aspectRatio,
          rotation: image.rotation,
          captions: image.captions,
        ),
      );
      await adapter.replaceFromRemote([remote]);
      final desired = _block(image, url: 'https://example.test/replaced.png');
      expect(
        await applyCollabImageEdit(adapter.editorState, original, desired),
        isTrue,
      );
      expect(adapter.blocks.single.image!.widthRatio, 30);
      expect(adapter.blocks.single.text, desired.text);
      final conflicting = _block(
        CollabImage(
          widthRatio: 80,
          aspectRatio: image.aspectRatio,
          rotation: image.rotation,
          captions: image.captions,
        ),
      );
      await expectLater(
        applyCollabImageEdit(adapter.editorState, original, conflicting),
        throwsStateError,
      );
      expect(adapter.blocks.single.image!.widthRatio, 30);
    },
  );

  test(
    'readonly and deleted image reject writes, deletion keeps an editable paragraph',
    () async {
      final original = _block(image);
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [original],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      adapter.editorState.editable = false;
      expect(
        await applyCollabImageEdit(adapter.editorState, original, original),
        isFalse,
      );
      expect(
        await deleteCollabImage(adapter.editorState, original.id),
        isFalse,
      );
      adapter.editorState.editable = true;
      expect(await deleteCollabImage(adapter.editorState, original.id), isTrue);
      expect(adapter.blocks.single.blockType, ParagraphBlockKeys.type);
      expect(adapter.editorState.selection?.start.path, [0]);
      expect(
        await applyCollabImageEdit(adapter.editorState, original, original),
        isFalse,
      );
    },
  );

  testWidgets(
    'image shows layout caption and upload placeholder with readonly controls hidden',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_block(image)],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      adapter.editorState.editable = true;
      Widget view() => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: CollabImageContent(
                node: adapter.editorState.document.root.children.single,
                editorState: adapter.editorState,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(view());
      expect(
        tester.getSize(find.byKey(const ValueKey('collab-image-box'))),
        const Size(180, 120),
      );
      expect(find.text('图片题注😀'), findsOneWidget);
      expect(find.text('图片正在其他设备上传'), findsOneWidget);
      expect(find.byKey(const ValueKey('collab-image-edit')), findsNothing);
      expect(find.byType(IconButton), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('block-more-image-1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('collab-image-edit')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('collab-image-menu-delete')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      adapter.editorState.editable = false;
      await tester.pumpWidget(view());
      expect(find.byKey(const ValueKey('collab-image-edit')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image dialog saves caption and layout and releases controllers after close',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [_block(image)],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      adapter.editorState.editable = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: CollabImageContent(
                node: adapter.editorState.document.root.children.single,
                editorState: adapter.editorState,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('block-more-image-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collab-image-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('collab-image-width-input')),
        '0',
      );
      await tester.tap(find.byKey(const ValueKey('collab-image-save')));
      await tester.pump();
      expect(find.text('请填写有效的宽度比例和正数宽高比'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('collab-image-width-input')),
        '45',
      );
      await tester.enterText(
        find.byKey(const ValueKey('collab-image-caption-input-0')),
        '手机新题注',
      );
      await tester.tap(find.byKey(const ValueKey('collab-image-save')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collab-image-edit-dialog')),
        findsNothing,
      );
      expect(adapter.blocks.single.image!.widthRatio, 45);
      expect(adapter.blocks.single.image!.captions.single.text, '手机新题注');
      expect(adapter.blocks.single.image!.rotation, 15);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same node URL changes replace the network image provider', (
    tester,
  ) async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [_block(image, url: 'https://example.test/first.png')],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final node = adapter.editorState.document.root.children.single;
    Widget view() => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: CollabImageContent(
            node: node,
            editorState: adapter.editorState,
          ),
        ),
      ),
    );
    await tester.pumpWidget(view());
    expect(
      (tester.widget<Image>(find.byType(Image)).image as NetworkImage).url,
      'https://example.test/first.png',
    );
    await adapter.editorState.apply(
      adapter.editorState.transaction..updateNode(node, {
        ImageBlockKeys.url: 'https://example.test/second.png',
      }),
      isRemote: true,
    );
    await tester.pumpWidget(view());
    expect(
      (tester.widget<Image>(find.byType(Image)).image as NetworkImage).url,
      'https://example.test/second.png',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
