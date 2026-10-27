import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_image_block.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证真实编辑器中的图片宿主回调、输入隔离、菜单命中及迟到结果，不连接原生协同服务。
void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    for (final editable in [true, false]) {
      testWidgets(
        '$platform image tap forwards exact URL without input, editable=$editable',
        (tester) async {
          final received = <String>[];
          final changes = <List<CollabEditorBlock>>[];
          final harness = await _mount(
            tester,
            editable: editable,
            services: CollabHostServices(onImageTap: received.add),
            onChanged: changes.add,
          );
          final editor = harness.adapter.editorState;
          if (editable) {
            final selectionUpdate = editor.updateSelectionWithReason(
              Selection.collapsed(Position(path: [0], offset: 2)),
              reason: SelectionUpdateReason.uiEvent,
            );
            await tester.pumpAndSettle();
            await selectionUpdate;
            expect(tester.testTextInput.hasAnyClients, isTrue);
          }
          tester.testTextInput.log.clear();
          await tester.tap(_tap);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 500));
          expect(received, [_url]);
          expect(editor.selection, isNull);
          expect(tester.testTextInput.hasAnyClients, isFalse);
          expect(_keyboardShows(tester), isEmpty);
          expect(changes, isEmpty);
          expect(editor.undoManager.undoStack, isEmpty);
          if (editable) {
            await tester.tap(find.byKey(editor.document.first!.key));
            await tester.pumpAndSettle();
            expect(editor.selection?.start.path, [0]);
            expect(
              tester.testTextInput.hasAnyClients,
              isTrue,
              reason: '点击正文仍能重新输入',
            );
          }
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }

  for (final configured in [false, true]) {
    testWidgets('selected image suppresses focus with callback=$configured', (
      tester,
    ) async {
      final received = <String>[];
      final harness = await _mount(
        tester,
        services: CollabHostServices(
          onImageTap: configured ? received.add : null,
        ),
      );
      final editor = harness.adapter.editorState;
      editor.selectionType = SelectionType.block;
      editor.selection = Selection.single(
        path: [1],
        startOffset: 0,
        endOffset: 1,
      );
      await tester.pumpAndSettle();
      tester.testTextInput.log.clear();
      await tester.tap(_tap);
      await tester.pumpAndSettle();
      expect(received, configured ? [_url] : isEmpty);
      expect(editor.selection, isNull);
      expect(_keyboardShows(tester), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'empty image source suppresses focus without callback or changes',
    (tester) async {
      final received = <String>[];
      final changes = <List<CollabEditorBlock>>[];
      final harness = await _mount(
        tester,
        services: CollabHostServices(onImageTap: received.add),
        onChanged: changes.add,
      );
      await harness.adapter.replaceFromRemote([_before, _image(''), _after]);
      await tester.pumpAndSettle();
      tester.testTextInput.log.clear();
      await tester.tap(_tap);
      await tester.pumpAndSettle();
      expect(received, isEmpty);
      expect(_keyboardShows(tester), isEmpty);
      expect(harness.adapter.editorState.selection, isNull);
      expect(changes, isEmpty);
      expect(harness.adapter.editorState.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('caption and more menu do not trigger image callback', (
    tester,
  ) async {
    final received = <String>[];
    await _mount(
      tester,
      services: CollabHostServices(onImageTap: received.add),
    );
    await tester.tap(find.text('独立题注'));
    await tester.pumpAndSettle();
    expect(received, isEmpty);
    await tester.tap(find.byKey(const ValueKey('block-more-image')));
    await tester.pumpAndSettle();
    expect(find.text('复制链接'), findsOneWidget);
    expect(received, isEmpty);
    Navigator.of(tester.element(find.text('复制链接'))).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
  });

  for (final outcome in ['success', 'failure', 'source', 'host', 'dispose']) {
    testWidgets('pending image callback handles $outcome without refocusing', (
      tester,
    ) async {
      final pending = Completer<void>();
      final received = <String>[];
      final errors = <Object>[];
      final harness = await _mount(
        tester,
        services: CollabHostServices(
          onImageTap: (url) {
            received.add(url);
            return pending.future;
          },
          onError: (_, error, _, _) => errors.add(error),
        ),
      );
      await tester.tap(_tap);
      await tester.pump();
      await tester.tap(_tap);
      await tester.pump();
      expect(received, [_url], reason: '宿主预览关闭前只派发一次');
      if (outcome == 'source') {
        await harness.adapter.replaceFromRemote([
          _before,
          _image('https://example.test/new.png'),
          _after,
        ]);
        await tester.pumpAndSettle();
      } else if (outcome == 'host') {
        CollabRuntime.acquire(harness.owner, const CollabHostServices());
      } else if (outcome == 'dispose') {
        await tester.pumpWidget(const SizedBox());
      }
      tester.testTextInput.log.clear();
      if (outcome == 'success') {
        pending.complete();
      } else {
        pending.completeError(StateError('fixture preview failure'));
      }
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(errors, hasLength(outcome == 'failure' ? 1 : 0));
      expect(
        find.text('打开图片失败，请重试'),
        outcome == 'failure' ? findsOneWidget : findsNothing,
      );
      expect(_keyboardShows(tester), isEmpty);
      expect(harness.adapter.editorState.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

/// 带签名及片段的原始链接，用于确认宿主回调不重新编码或截断地址。
const _url =
    'https://example.test/%E4%B8%AD%20image.png?signature=a%2Bb%2Fc%3D#preview';

/// 图片之前的可输入正文，验证点击图片会关闭已有输入。
const _before = CollabEditorBlock(
  id: 'before',
  blockType: 'paragraph',
  text: '前置正文',
);

/// 图片之后的可输入正文，避免末块补段落影响历史断言。
const _after = CollabEditorBlock(
  id: 'after',
  blockType: 'paragraph',
  text: '后置正文',
);

/// 图片本体独立的点击命中区域，不包含题注或更多菜单。
final _tap = find.byKey(const ValueKey('collab-image-tap-image'));

/// 从[tester]的平台日志中提取打开键盘请求，不把关闭请求算作获取焦点。
Iterable<MethodCall> _keyboardShows(WidgetTester tester) =>
    tester.testTextInput.log.where((call) => call.method == 'TextInput.show');

/// 使用原始链接[url]构造带题注的正式图片投影；不进行上传或网络请求。
CollabEditorBlock _image(String url) => CollabEditorBlock(
  id: 'image',
  blockType: 'image',
  text: url,
  image: const CollabImage(
    widthRatio: 60,
    aspectRatio: 2,
    captions: [CollabImageCaption(id: 'caption', text: '独立题注')],
  ),
);

/// 测试拥有的编辑器及运行时会话，统一在挂载辅助方法的清理阶段释放。
class _Harness {
  /// [adapter]由测试创建并持有，[owner]限定宿主运行时会话身份。
  _Harness(this.adapter, this.owner);

  /// 测试拥有的编辑器适配器。
  final AppFlowyBlockEditorAdapter adapter;

  /// 测试拥有的运行时身份。
  final Object owner;
}

/// 在[tester]挂载真实编辑器，注入借用的[services]；[editable]默认为编辑模式。
/// [onChanged]接收本地正文发布，null忽略；测试退出时先卸载Widget，再释放编辑器、会话和视口。
Future<_Harness> _mount(
  WidgetTester tester, {
  required CollabHostServices services,
  bool editable = true,
  void Function(List<CollabEditorBlock>)? onChanged,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  final owner = Object();
  CollabRuntime.acquire(owner, services);
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [_before, _image(_url), _after],
    onLocalBlocksChanged: onChanged ?? (_) {},
  );
  adapter.editorState.editable = editable;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
    CollabRuntime.release(owner);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.binding.setSurfaceSize(null);
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
        body: AppFlowyEditor(
          editorState: adapter.editorState,
          editable: editable,
          editorStyle: const EditorStyle.mobile(),
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            'image': CollabImageBlockComponentBuilder(),
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(adapter, owner);
}
