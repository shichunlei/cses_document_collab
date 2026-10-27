import 'dart:io';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_divider_block.dart';
import 'package:cses_document_collab/src/editor/collab_divider_settings.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/ui/modal/collab_switch_row.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证创建草稿、面板内锁转换、复制、结构命令及远端/撤权后的陈旧操作保护。
void main() {
  setUpAll(() async {
    final font = Platform.environment['COLLAB_MODAL_PREVIEW_FONT'];
    if (font == null) return;
    final bytes = await File(font).readAsBytes();
    await (FontLoader('ModalPreview')..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    await (FontLoader(
      'packages/lucide_icons_flutter/Lucide',
    )..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'))).load();
  });
  testWidgets('lock switch alone toggles, hides actions, and unlock restores live editing', (tester) async {
    final fixture = await _mount(tester);
    await _openPanel(tester);
    final lockRow = find.byKey(const ValueKey('block-lock-line'));
    await tester.ensureVisible(lockRow);
    await tester.tap(find.text('锁定', findRichText: true));
    await tester.pumpAndSettle();
    expect(fixture.locks.state('line').locked, isFalse);
    await _capture(tester, 'divider-edit');
    final switchFinder = find.descendant(of: lockRow, matching: find.byType(CupertinoSwitch));
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(fixture.locks.state('line').locked, isTrue);
    expect(find.byKey(const ValueKey('collab-divider-settings')), findsOneWidget);
    expect(find.byKey(const ValueKey('divider-delete')), findsNothing);
    expect(find.byKey(const ValueKey('divider-insert-below')), findsNothing);
    expect(find.byKey(const ValueKey('divider-copy-link')), findsOneWidget);
    expect(tester.widget<Slider>(find.byKey(const ValueKey('divider-opacity'))).onChanged, isNull);
    await _capture(tester, 'divider-locked');
    await tester.ensureVisible(switchFinder);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(fixture.locks.state('line').locked, isFalse);
    expect(find.byKey(const ValueKey('divider-delete')), findsOneWidget);
    expect(find.byKey(const ValueKey('divider-insert-below')), findsOneWidget);
    expect(fixture.adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
    await tester.ensureVisible(find.byKey(const ValueKey('divider-style-wave')));
    await tester.tap(find.byKey(const ValueKey('divider-style-wave')));
    await tester.pumpAndSettle();
    expect(CollabDivider(fixture.adapter.blocks.first.resource!.values).style, 'wave');
    expect(tester.takeException(), isNull);
  });

  testWidgets('locked divider copies host block link without document or history changes', (tester) async {
    final fixture = await _mount(tester, locked: true);
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final before = fixture.adapter.editorState.document.toJson();
    await _openPanel(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('divider-copy-link')));
    await tester.tap(find.byKey(const ValueKey('divider-copy-link')));
    await tester.pumpAndSettle();
    expect(copied, 'https://example.test/doc/doc-1?blockId=line');
    expect(fixture.adapter.editorState.document.toJson(), before);
    expect(fixture.adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
    expect(fixture.adapter.editorState.selection, isNull);
  });

  for (final change in ['lock-cycle', 'permission-cycle', 'delete']) {
    testWidgets('$change permanently invalidates open panel writes', (tester) async {
      final fixture = await _mount(tester);
      await _openPanel(tester);
      final staleChange = tester.widget<Slider>(find.byKey(const ValueKey('divider-opacity'))).onChangeEnd!;
      if (change == 'lock-cycle') {
        fixture.locks.update([const CollabBlockLockState(blockId: 'line', sourceId: 'line', ownerId: 'u2')]);
        fixture.locks.update([const CollabBlockLockState(blockId: 'line')]);
      } else if (change == 'permission-cycle') {
        fixture.adapter.editorState.editable = false;
        fixture.adapter.editorState.editable = true;
      } else {
        await fixture.adapter.replaceFromRemote([fixture.adapter.blocks.last]);
      }
      await tester.pumpAndSettle();
      staleChange(.2);
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(find.byKey(const ValueKey('divider-opacity'))).onChanged, isNull);
      expect(fixture.adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
      if (change != 'delete') expect(CollabDivider(fixture.adapter.blocks.first.resource!.values).opacity, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('below inserts after target and delete remains an independent undo step', (tester) async {
    final fixture = await _mount(tester);
    final editor = fixture.adapter.editorState;
    await _openPanel(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('divider-insert-below')));
    await tester.tap(find.byKey(const ValueKey('divider-insert-below')));
    await tester.pumpAndSettle();
    expect(fixture.adapter.blocks.map((b) => b.blockType), ['divider', 'paragraph', 'paragraph']);
    expect(editor.selection?.start.path, [1]);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await _openPanel(tester);
    await tester.tap(find.byKey(const ValueKey('divider-delete')));
    await tester.pumpAndSettle();
    expect(fixture.adapter.blocks.map((b) => b.blockType), ['paragraph', 'paragraph']);
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(fixture.adapter.blocks.first.id, 'line');
    expect(fixture.adapter.blocks, hasLength(3));
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(fixture.adapter.blocks, hasLength(2));
    expect(fixture.adapter.blocks.last.id, 'tail');
    expect(tester.takeException(), isNull);
  });

  testWidgets('creation cancel keeps draft local and revoked creation cannot complete', (tester) async {
    final fixture = await _mount(tester);
    final context = tester.element(find.byType(AppFlowyEditor));
    var completed = false;
    CollabDivider? result;
    final future = showCollabDividerInput(context, fixture.adapter.editorState).then((value) {
      completed = true;
      result = value;
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('divider-style-wave')));
    await tester.pumpAndSettle();
    await _capture(tester, 'divider-create');
    expect(completed, isFalse);
    expect(CollabDivider(fixture.adapter.blocks.first.resource!.values).style, 'solid');
    expect(find.byType(CollabSwitchRow), findsNothing);
    expect(fixture.adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await future;
    expect(result, isNull);
    final second = showCollabDividerInput(context, fixture.adapter.editorState);
    await tester.pumpAndSettle();
    fixture.adapter.editorState.editable = false;
    fixture.adapter.editorState.editable = true;
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('divider-done'))).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await second, isNull);
  });
}

/// 打开当前真实分割线面板并等待路由动画；[tester]持有测试树。
Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('collab-divider-line')));
  await tester.pumpAndSettle();
}

/// 挂载真实编辑器和宿主绑定；[tester]持有树，[locked]控制初始普通锁。
/// 每个测试先卸载树，再释放本夹具创建的链接、锁和编辑器资源。
Future<({AppFlowyBlockEditorAdapter adapter, CollabBlockLocks locks})> _mount(
  WidgetTester tester, {
  bool locked = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: const [
      CollabEditorBlock(id: 'line', blockType: 'divider', text: '', resource: CollabResource()),
      CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '正文'),
    ],
    onLocalBlocksChanged: (_) {},
  );
  late CollabBlockLocks locks;
  locks = CollabBlockLocks(
    editor: adapter.editorState,
    userId: 'u1',
    canUnlock: (_) => false,
    commit: (id, value, expected) async {
      expect(locks.state(id), expected);
      locks.update([CollabBlockLockState(blockId: id, sourceId: value ? id : null, ownerId: value ? 'u1' : null)]);
    },
  );
  locks.update([
    CollabBlockLockState(blockId: 'line', sourceId: locked ? 'line' : null, ownerId: locked ? 'u1' : null),
  ]);
  final links = CollabParagraphLinks(
    editor: adapter.editorState,
    documentId: 'doc-1',
    buildLink: (doc, block) => 'https://example.test/doc/$doc?blockId=$block',
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    links.dispose();
    locks.dispose();
    adapter.dispose();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('divider-panel-capture'),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: Platform.environment['COLLAB_MODAL_PREVIEW_FONT'] == null ? null : 'ModalPreview'),
        home: Scaffold(
          body: AppFlowyEditor(
            editorState: adapter.editorState,
            disableKeyboardService: true,
            editorStyle: const EditorStyle.mobile(),
            blockComponentBuilders: {
              ...standardBlockComponentBuilderMap,
              'divider': CollabDividerBlockComponentBuilder(),
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (adapter: adapter, locks: locks);
}

/// 将[tester]的真实面板写入[name] PNG；仅配置预览目录时运行，图像创建者负责释放。
Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['COLLAB_MODAL_PREVIEW_DIR'];
  if (output == null) return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('divider-panel-capture')));
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
