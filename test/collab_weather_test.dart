import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/blockcraft_json_codec.dart';
import 'package:cses_document_collab/src/editor/blockcraft_snapshot_view.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_weather_block.dart';
import 'package:cses_document_collab/src/editor/collab_weather_settings.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_weather.dart';
import 'package:cses_document_collab/src/ui/modal/collab_weather_visual.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 天气块正式协议、历史、设置草稿、异步会话及窄屏布局回归。
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
  });
  test('frozen weather requires valid data and live mode ignores old frozen', () {
    final raw = {'temp': 20, 'condition': '晴', 'location': '北京', 'tone': 'future'};
    final fixed = CollabWeather({'date': '2026-10-25', 'frozen': raw, 'style': 'future'});
    expect(fixed.frozen!.tone, 'sunny');
    expect(fixed.style, 'classic');
    expect(CollabWeather({'date': 'live', 'frozen': raw}).frozen, isNull);
    expect(CollabWeatherData.read({'temp': double.nan, 'condition': '晴'}), isNull);
    expect(CollabWeatherData.read({'temp': 20, 'condition': '晴', 'low': false}), isNull);
    expect(weatherSize('classic'), (width: 160.0, height: 42.0));
  });

  test('explicit patches preserve frozen, undo after reorder and reject invalid fields', () async {
    final published = <List<CollabEditorBlock>>[];
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: published.add);
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    expect(await changeCollabWeatherProperties(state, 'weather', {'style': 'ledger', 'range': 'off'}), isTrue);
    expect(jsonDecode(published.last.first.resource!.propertyEdits!), {
      'style': {'value': 'ledger'},
      'range': {'value': 'off'},
    });
    final updated = adapter.blocks;
    await adapter.replaceFromRemote([updated.last, updated.first]);
    state.undoManager.undo();
    await pumpEventQueue();
    expect(adapter.blocks.last.resource!.values['style'], 'classic');
    expect(adapter.blocks.last.resource!.values['frozen'], _weather.toJson());
    state.undoManager.redo();
    await pumpEventQueue();
    expect(adapter.blocks.last.resource!.values['range'], 'off');
    for (final pair in [
      ('style', 'future'),
      ('range', false),
      ('width', 0),
      ('url', 'https://example.test'),
      ('frozen', {'temp': '20'}),
    ]) {
      expect(await changeCollabWeatherProperty(state, 'weather', pair.$1, pair.$2), isFalse);
    }
  });

  test('insert, preceding backspace and undo preserve stable identity and frozen data', () async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '')],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final landing = await insertCollabWeather(
      adapter.editorState,
      Selection.single(path: [0], startOffset: 0),
      values: {'frozen': _weather.toJson()},
    );
    final inserted = adapter.blocks.first;
    expect(inserted.blockType, 'weather');
    expect(inserted.text, isEmpty);
    adapter.editorState.selection = landing;
    expect(await deletePreviousUrlBackedBlock(adapter.editorState), isTrue);
    adapter.editorState.undoManager.undo();
    await pumpEventQueue();
    expect(adapter.blocks.first.id, inserted.id);
    expect(adapter.blocks.first.resource!.values, inserted.resource!.values);
  });

  test('JSON creates native weather and cleared palette overrides never revive', () async {
    final fixture =
        jsonDecode(await File('rust/tests/fixtures/blockcraft-weather.json').readAsString()) as Map<String, dynamic>;
    fixture['children'] = [(fixture['children'] as List).first];
    final owner = DocumentEditorController(document: BlockCraftJsonCodec.decode(fixture));
    addTearDown(owner.close);
    expect(owner.editorState.document.root.children.single.type, 'weather');
    await changeCollabWeatherProperties(owner.editorState, 'weather-0', {'fg': '#123456', 'palette': 'blue'});
    await changeCollabWeatherProperty(owner.editorState, 'weather-0', 'fg', null);
    final exported = BlockCraftJsonCodec.encode(owner.editorState.document);
    final card = (exported['children'] as List).single;
    expect(card['props'].containsKey('fg'), isFalse);
    expect(card['props']['frozen']['temp'], 20);
    expect(card['props']['futureProp'], {'preserve': true});
    expect(card['meta']['audit'], 'desktop');
  });

  test('legacy local snapshot-weather retains frozen props on export and its renderer', () {
    final document = Document(
      root: Node(
        type: 'page',
        children: [
          Node(
            type: 'snapshot-weather',
            attributes: {
              'bc.p:date': {'v': '2026-10-25'},
              'bc.p:frozen': {'v': _weather.toJson()},
              'bc.p:future': {'v': 'preserved'},
            },
          ),
        ],
      ),
    );
    addTearDown(document.dispose);
    final exported = BlockCraftJsonCodec.encode(document);
    final props = (exported['children'] as List).single['props'] as Map;
    expect(props['date'], '2026-10-25');
    expect(props['frozen'], _weather.toJson());
    expect(props['future'], 'preserved');
    expect(blockCraftSnapshotBuilders({}).containsKey('snapshot-weather'), isTrue);
  });

  for (final scale in [1.0, 2.2]) {
    testWidgets('seven layouts six palettes at 280px and text scale $scale', (tester) async {
      for (final style in collabWeatherLayouts.keys) {
        for (final palette in collabWeatherPalettes.keys) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                  child: SizedBox(
                    width: 280,
                    child: CollabWeatherVisual(
                      card: CollabWeather({'style': style, 'palette': palette, 'bw': '3px double', 'width': 600}),
                      weather: _weather,
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: '$style/$palette');
          expect(tester.getSize(find.byType(CollabWeatherVisual)).width, 280);
        }
      }
    });
  }

  testWidgets('settings cancel no write; apply once, preserve frozen and undo', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    await _settingsHost(tester, adapter.editorState);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-style-previous')));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(adapter.editorState.undoManager.undoStack, isEmpty);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('weather-style-previous')));
    await tester.tap(find.byKey(const ValueKey('weather-apply')));
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['style'], 'ledger');
    expect(adapter.blocks.first.resource!.values['frozen'], _weather.toJson());
    adapter.editorState.undoManager.undo();
    await tester.pump();
    expect(adapter.blocks.first.resource!.values['style'], 'classic');
    expect(adapter.editorState.undoManager.undoStack, isEmpty);
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  testWidgets('old draft remains invalid after lock/unlock and remote edits', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    final locks = CollabBlockLocks(
      editor: adapter.editorState,
      userId: 'u1',
      canUnlock: (_) => false,
      commit: (_, _, _) async {},
    );
    locks.update(const [CollabBlockLockState(blockId: 'weather')]);
    await _settingsHost(tester, adapter.editorState);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    locks.update(const [CollabBlockLockState(blockId: 'weather', sourceId: 'weather', ownerId: 'u2')]);
    locks.update(const [CollabBlockLockState(blockId: 'weather')]);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('weather-apply'))).onPressed, isNull);
    expect(await changeCollabWeatherProperty(adapter.editorState, 'weather', 'range', 'off'), isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    locks.dispose();
    adapter.dispose();
  });

  for (final scenario in ['locked', 'readonly', 'no-service']) {
    testWidgets('weather refresh menu excludes unavailable action: $scenario', (tester) async {
      var calls = 0;
      final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
      EditorCommandContext.bind(
        adapter.editorState,
        EditorCommandContext(
          services: CollabHostServices(
            loadWeather: scenario == 'no-service'
                ? null
                : ({date, required refresh, required cancelled}) async {
                    calls++;
                    return _weather;
                  },
          ),
        ),
      );
      final locks = CollabBlockLocks(
        editor: adapter.editorState,
        userId: 'u1',
        canUnlock: (_) => false,
        commit: (_, _, _) async {},
      );
      locks.update([
        CollabBlockLockState(
          blockId: 'weather',
          sourceId: scenario == 'locked' ? 'weather' : null,
          ownerId: scenario == 'locked' ? 'u2' : null,
        ),
      ]);
      if (scenario == 'readonly') adapter.editorState.editable = false;
      await _contentHost(tester, adapter);
      await _openWeatherMenu(tester);
      expect(find.byKey(const ValueKey('weather-refresh')), findsNothing);
      expect(calls, 0);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      locks.dispose();
      adapter.dispose();
    });
  }

  testWidgets('fixed snapshot avoids requests; explicit refresh is undoable and failure keeps old data', (
    tester,
  ) async {
    var calls = 0;
    var fail = false;
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    EditorCommandContext.bind(
      adapter.editorState,
      EditorCommandContext(
        services: CollabHostServices(
          onError: (_, _, _, _) {},
          loadWeather: ({date, required refresh, required cancelled}) async {
            calls++;
            expect(date, '2026-10-25');
            expect(refresh, isTrue);
            if (fail) throw StateError('offline');
            return const CollabWeatherData(temp: 26, condition: '多云', location: '北京', tone: 'cloudy');
          },
        ),
      ),
    );
    await _contentHost(tester, adapter);
    expect(calls, 0);
    await _refreshFromMenu(tester);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(adapter.blocks.first.resource!.values['frozen']['temp'], 26);
    adapter.editorState.undoManager.undo();
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['frozen']['temp'], 20);
    fail = true;
    await _refreshFromMenu(tester);
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['frozen']['temp'], 20);
    expect(find.textContaining('天气加载失败，请重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-refresh')), findsNothing);
    await _openWeatherMenu(tester);
    expect(find.text('刷新天气'), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('weather-refresh')));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(adapter.blocks.first.resource!.values['frozen']['temp'], 26);
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  testWidgets('live responses never persist; revoked pending refresh cannot write after restore', (tester) async {
    final response = Completer<CollabWeatherData>();
    final adapter = AppFlowyBlockEditorAdapter(initialBlocks: _blocks(), onLocalBlocksChanged: (_) {});
    EditorCommandContext.bind(
      adapter.editorState,
      EditorCommandContext(
        services: CollabHostServices(loadWeather: ({date, required refresh, required cancelled}) => response.future),
      ),
    );
    await _contentHost(tester, adapter);
    await _refreshFromMenu(tester);
    await tester.pump();
    adapter.editorState.editable = false;
    adapter.editorState.editable = true;
    response.complete(const CollabWeatherData(temp: 99, condition: '晴', location: '迟到'));
    await tester.pumpAndSettle();
    expect(adapter.blocks.first.resource!.values['frozen']['temp'], 20);
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();

    final live = AppFlowyBlockEditorAdapter(
      initialBlocks: [
        CollabEditorBlock(
          id: 'weather',
          blockType: 'weather',
          text: '',
          resource: CollabResource.fromValues({'date': 'live'}),
        ),
      ],
      onLocalBlocksChanged: (_) {},
    );
    EditorCommandContext.bind(
      live.editorState,
      EditorCommandContext(
        services: CollabHostServices(loadWeather: ({date, required refresh, required cancelled}) async => _weather),
      ),
    );
    await _contentHost(tester, live);
    await tester.pumpAndSettle();
    expect(live.blocks.first.resource!.values.containsKey('frozen'), isFalse);
    expect(live.editorState.undoManager.undoStack, isEmpty);
    await tester.pumpWidget(const SizedBox());
    live.dispose();
  });

  testWidgets('fixed-date query cannot save after permission is revoked then restored', (tester) async {
    final response = Completer<CollabWeatherData>();
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [
        CollabEditorBlock(
          id: 'weather',
          blockType: 'weather',
          text: '',
          resource: CollabResource.fromValues({'date': 'live'}),
        ),
      ],
      onLocalBlocksChanged: (_) {},
    );
    EditorCommandContext.bind(
      adapter.editorState,
      EditorCommandContext(
        services: CollabHostServices(loadWeather: ({date, required refresh, required cancelled}) => response.future),
      ),
    );
    await _settingsHost(tester, adapter.editorState);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('定格日期'));
    await tester.tap(find.byKey(const ValueKey('weather-apply')));
    await tester.pump();
    adapter.editorState.editable = false;
    adapter.editorState.editable = true;
    response.complete(_weather);
    await tester.pumpAndSettle();
    expect(adapter.blocks.single.resource!.values, {'date': 'live'});
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('weather-apply'))).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
  });

  testWidgets('native seven style gallery', (tester) async {
    const output = String.fromEnvironment('WEATHER_PREVIEW_DIR');
    const font = String.fromEnvironment('WEATHER_PREVIEW_FONT');
    if (font.isNotEmpty) {
      await tester.runAsync(() async {
        final loader = FontLoader('WeatherPreview')..addFont(File(font).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      });
    }
    if (output.isNotEmpty) {
      await tester.runAsync(() async {
        final icons = FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf'));
        await icons.load();
      });
    }
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: font.isEmpty ? null : 'WeatherPreview'),
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in collabWeatherLayouts.entries) ...[
                    Text(entry.value.label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    CollabWeatherVisual(
                      card: CollabWeather({'style': entry.key, 'palette': 'blue'}),
                      weather: _weather,
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (output.isNotEmpty) {
      await tester.runAsync(() async {
        final capture = await (boundary.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(
          pixelRatio: 2,
        );
        final data = await capture.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File('$output/weather-gallery.png').writeAsBytes(data!.buffer.asUint8List());
        capture.dispose();
      });
    }
  });
}

/// 测试用真实形状的固定快照，不发网络请求。
const _weather = CollabWeatherData(temp: 20, condition: '晴', location: '北京', high: 25, low: 15);

/// 创建独立夹具，避免不同测试共享可变属性。
List<CollabEditorBlock> _blocks() => [
  CollabEditorBlock(
    id: 'weather',
    blockType: 'weather',
    text: '',
    resource: CollabResource.fromValues({'date': '2026-10-25', 'style': 'classic', 'frozen': _weather.toJson()}),
  ),
  const CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '正文'),
];

/// 由 [tester] 承载借用 [state] 的设置入口；调用方卸载后释放状态。
Future<void> _settingsHost(WidgetTester tester, EditorState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => await showCollabWeatherSettings(context, state, 'weather'),
            child: const Text('设置'),
          ),
        ),
      ),
    ),
  );
}

/// 由 [tester] 承载借用 [adapter] 的正式天气块与公共操作菜单，不关闭编辑器。
Future<void> _contentHost(WidgetTester tester, AppFlowyBlockEditorAdapter adapter) async {
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
          editable: adapter.editorState.editable,
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            'weather': CollabWeatherBlockComponentBuilder(),
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 使用[tester]点击天气卡片打开操作菜单；正文不直接提供刷新按钮。
Future<void> _openWeatherMenu(WidgetTester tester) async {
  expect(find.byKey(const ValueKey('weather-refresh')), findsNothing);
  await tester.tap(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '天气卡片操作'));
  await tester.pumpAndSettle();
}

/// 使用[tester]执行公共菜单中的刷新，并等待菜单退场及请求启动。
Future<void> _refreshFromMenu(WidgetTester tester) async {
  await _openWeatherMenu(tester);
  final refresh = find.byKey(const ValueKey('weather-refresh'));
  expect((tester.widget<CollabMenuRow>(refresh).leading as Icon).icon, LucideIcons.refreshCw);
  await tester.tap(refresh);
  await tester.pumpAndSettle();
}
