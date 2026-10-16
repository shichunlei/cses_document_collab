import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:cses_document_collab/src/editor/collab_code_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const _source =
    "import 'package:flutter/widgets.dart';\n\nvoid main() {\n  print('代码😀');\n}\n";

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

  testWidgets(
    'header edits name and language, collapse keeps source and supports undo',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'code',
            blockType: csesCodeBlockType,
            text: _source,
            code: CollabCode(language: 'Dart', name: '旧名称'),
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await _pumpEditor(tester, adapter);
      final node = adapter.editorState.document.first!;
      final before = node.delta!.toJson();

      await tester.tap(find.byKey(const ValueKey('collab-code-name')));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('collab-code-name-input'));
      expect(
        tester.widget<TextField>(input).controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 3),
      );
      await tester.enterText(input, '  新名称  ');
      await tester.tap(find.byKey(const ValueKey('collab-code-name-save')));
      await tester.pumpAndSettle();
      expect(find.text('新名称'), findsOneWidget);
      expect(
        changes.last.single.code!.propertyEdits,
        '{"blockName":{"value":"新名称"}}',
      );

      await tester.tap(find.byKey(const ValueKey('collab-code-language')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('collab-code-language-search')),
        'Python',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('collab-code-language-Python')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Python'), findsOneWidget);
      expect(
        changes.last.single.code!.propertyEdits,
        '{"lang":{"value":"Python"}}',
      );
      expect(adapter.blocks.single.code!.name, '新名称');

      adapter.editorState.selection = Selection.single(
        path: [0],
        startOffset: 3,
      );
      await tester.tap(find.byKey(const ValueKey('collab-code-collapse')));
      await tester.pumpAndSettle();
      expect(find.byType(AppFlowyRichText), findsNothing);
      expect(tester.getSize(find.byKey(node.key)).height, lessThan(54));
      expect(adapter.editorState.selection, isNull);
      expect(node.delta!.toJson(), before);
      expect(
        changes.last.single.code!.propertyEdits,
        '{"collapse":{"value":true}}',
      );
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(find.byType(AppFlowyRichText), findsOneWidget);
      expect(adapter.blocks.single.code!.name, '新名称');
      expect(adapter.blocks.single.code!.language, 'Python');
      adapter.editorState.undoManager.redo();
      await tester.pumpAndSettle();
      expect(find.byType(AppFlowyRichText), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'code property undo follows target identity and keeps remote fields',
    () async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: 'code',
            blockType: csesCodeBlockType,
            text: _source,
            code: CollabCode.fromProperties({
              'lang': 'Dart',
              'blockName': null,
            }),
          ),
          const CollabEditorBlock(
            id: 'other',
            blockType: csesCodeBlockType,
            text: 'other',
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await changeCollabCodeProperty(
        adapter.editorState,
        'code',
        'blockName',
        'local',
      );
      await adapter.replaceFromRemote([
        const CollabEditorBlock(
          id: 'other',
          blockType: csesCodeBlockType,
          text: 'other',
        ),
        CollabEditorBlock(
          id: 'code',
          blockType: csesCodeBlockType,
          text: _source,
          code: CollabCode.fromProperties({
            'lang': 'Rust',
            'blockName': 'local',
            'collapse': true,
          }),
        ),
      ]);
      final caret = Selection.single(path: [0], startOffset: 2);
      adapter.editorState.selection = caret;
      adapter.editorState.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      final code = changes.last.last.code!;
      expect(adapter.editorState.selection, caret);
      expect(changes.last.last.id, 'code');
      expect(code.language, 'Rust');
      expect(code.collapsed, isTrue);
      expect(code.propertyEdits, '{"blockName":{"value":null}}');
      final count = changes.length;
      await adapter.replaceFromRemote([adapter.blocks.first]);
      adapter.editorState.undoManager.redo();
      await Future<void>.delayed(Duration.zero);
      expect(changes.length, count);
      adapter.editorState.editable = false;
      expect(
        await changeCollabCodeProperty(
          adapter.editorState,
          'other',
          'lang',
          'Dart',
        ),
        isFalse,
      );
    },
  );

  testWidgets(
    'remote collapse preserves node and restores updated source on expand',
    (tester) async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'code',
            blockType: csesCodeBlockType,
            text: _source,
            code: CollabCode(language: 'Dart'),
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      await _pumpEditor(tester, adapter);
      final node = adapter.editorState.document.first!;
      adapter.editorState.selection = Selection.single(
        path: [0],
        startOffset: 1,
      );
      const remote = 'const int number = 42;';
      await adapter.replaceFromRemote(const [
        CollabEditorBlock(
          id: 'code',
          blockType: csesCodeBlockType,
          text: remote,
          code: CollabCode(language: 'PlainText', collapsed: true),
        ),
      ]);
      await tester.pumpAndSettle();
      expect(adapter.editorState.document.first, same(node));
      expect(adapter.editorState.selection, isNull);
      expect(find.byType(AppFlowyRichText), findsNothing);
      expect(changes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('collab-code-collapse')));
      await tester.pumpAndSettle();
      final span = _bodySpan(tester, remote);
      expect(
        span.children!.whereType<TextSpan>().any(
          (child) => child.style?.color == const Color(0xFFD73A49),
        ),
        isFalse,
      );
      expect(adapter.blocks.single.text, remote);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'code shell highlights without changing Delta and copies exact source',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'code',
            blockType: csesCodeBlockType,
            text: _source,
            code: CollabCode(language: 'Dart', name: '这是一段dart代码'),
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final before = adapter.editorState.document.first!.delta!.toJson();
      await _pumpEditor(tester, adapter);
      expect(find.text('这是一段dart代码'), findsOneWidget);
      expect(find.text('Dart'), findsOneWidget);
      final body = _bodySpan(tester, _source);
      expect(body.style!.fontSize, 13);
      expect(body.style!.fontFamily, 'monospace');
      expect(
        body.children!.whereType<TextSpan>().any(
          (span) =>
              span.text == 'import' &&
              span.style!.color == const Color(0xFFD73A49),
        ),
        isTrue,
      );
      expect(adapter.editorState.document.first!.delta!.toJson(), before);
      expect(changes, isEmpty);
      await tester.tap(find.byKey(const ValueKey('collab-code-copy')));
      await tester.pumpAndSettle();
      expect(copied, [_source]);
      expect(find.text('已复制'), findsOneWidget);
      expect(changes, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('复制'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('remote header refresh preserves node, caret, and undo history', (
    tester,
  ) async {
    final changes = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(
          id: 'code',
          blockType: csesCodeBlockType,
          text: _source,
          code: CollabCode(language: 'Dart', name: '旧名称'),
        ),
      ],
      onLocalBlocksChanged: changes.add,
    );
    addTearDown(adapter.dispose);
    await _pumpEditor(tester, adapter);
    final node = adapter.editorState.document.first!;
    final selection = Selection.single(path: [0], startOffset: 3);
    adapter.editorState.selection = selection;
    await adapter.replaceFromRemote(const [
      CollabEditorBlock(
        id: 'code',
        blockType: csesCodeBlockType,
        text: _source,
        code: CollabCode(language: 'Rust', name: '远端名称'),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(adapter.editorState.document.first, same(node));
    expect(adapter.editorState.selection, selection);
    expect(find.text('远端名称'), findsOneWidget);
    expect(find.text('Rust'), findsOneWidget);
    expect(changes, isEmpty);
    final transaction = adapter.editorState.transaction
      ..insertText(node, _source.length, '// local');
    await adapter.editorState.apply(transaction);
    await tester.pumpAndSettle();
    expect(
      _bodySpan(tester, '$_source// local').toPlainText(),
      '$_source// local',
    );
    expect(
      changes.single.single.code,
      const CollabCode(language: 'Rust', name: '远端名称'),
    );
    adapter.editorState.undoManager.undo();
    await tester.pumpAndSettle();
    expect(adapter.blocks.single.text, _source);
    expect(
      adapter.blocks.single.code,
      const CollabCode(language: 'Rust', name: '远端名称'),
    );
    adapter.editorState.undoManager.redo();
    await tester.pumpAndSettle();
    expect(adapter.blocks.single.text, '$_source// local');
    expect(
      adapter.blocks.single.code,
      const CollabCode(language: 'Rust', name: '远端名称'),
    );
    adapter.editorState.undoManager.undo();
    await tester.pumpAndSettle();
    expect(adapter.blocks.single.text, _source);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'unknown language and empty readonly code render safely on narrow screens',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(280, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'unknown',
            blockType: csesCodeBlockType,
            text: 'unknown <code> 😀',
            code: CollabCode(language: 'FutureLanguage', name: '很长很长的代码名称'),
          ),
          CollabEditorBlock(
            id: 'empty',
            blockType: csesCodeBlockType,
            text: '',
          ),
        ],
        onLocalBlocksChanged: (_) => fail('Readonly render must not publish'),
      );
      addTearDown(adapter.dispose);
      adapter.editorState.editable = false;
      await _pumpEditor(tester, adapter, editable: false);
      expect(find.text('纯文本'), findsOneWidget);
      expect(find.text('代码块'), findsOneWidget);
      expect(
        _bodySpan(tester, 'unknown <code> 😀').toPlainText(),
        'unknown <code> 😀',
      );
      expect(find.byKey(const ValueKey('collab-code-copy')), findsNWidgets(2));
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const ValueKey('collab-code-name')).first,
            )
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const ValueKey('collab-code-language')).first,
            )
            .onTap,
        isNull,
      );
      await tester.tap(
        find.byKey(const ValueKey('collab-code-collapse')).first,
      );
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.code!.collapsed, isFalse);
      expect(find.byType(AppFlowyRichText), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

TextSpan _bodySpan(WidgetTester tester, String text) => tester
    .widgetList<RichText>(
      find.descendant(
        of: find.byType(AppFlowyRichText),
        matching: find.byType(RichText),
      ),
    )
    .map((widget) => widget.text)
    .whereType<TextSpan>()
    .firstWhere((span) => span.toPlainText() == text);

Future<void> _pumpEditor(
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
        body: AppFlowyEditor(
          editorState: adapter.editorState,
          editable: editable,
          disableKeyboardService: !editable,
          editorStyle: const EditorStyle.mobile(
            padding: EdgeInsets.symmetric(horizontal: 20),
          ),
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            csesCodeBlockType: CollabCodeBlockComponentBuilder(),
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
