import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_mobile_selection_menu.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 为真实移动划词菜单持有编辑器、滚动和焦点资源，测试结束后统一释放。
final class _MenuHarness {
  /// 创建并拥有[state]的滚动控制器；正文由本测试创建和释放。
  _MenuHarness(this.state)
    : scroll = EditorScrollController(editorState: state);

  /// 测试拥有的正文状态，挂载期间只借给菜单和编辑视图。
  final EditorState state;

  /// 与编辑器和菜单共享的滚动控制器，由测试释放。
  final EditorScrollController scroll;

  /// 测试拥有的焦点节点，不依赖系统软键盘。
  final FocusNode focus = FocusNode();

  /// 在[tester]中挂载真实菜单，将[copy]绑定为实例复制端口并注册资源清理。
  static Future<_MenuHarness> mount(
    WidgetTester tester,
    Future<void> Function(Selection selection, {required bool cut}) copy,
  ) async {
    final harness = _MenuHarness(
      EditorState(
        document: Document(
          root: Node(
            type: PageBlockKeys.type,
            children: [paragraphNode(text: '前目标后')],
          ),
        ),
      ),
    );
    EditorCommandContext.bind(
      harness.state,
      EditorCommandContext(copySelection: copy),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      EditorCommandContext.unbind(harness.state);
      harness.scroll.dispose();
      harness.state.dispose();
      harness.focus.dispose();
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
          body: CollabMobileSelectionMenu(
            editorState: harness.state,
            scrollController: harness.scroll,
            child: AppFlowyEditor(
              editorState: harness.state,
              editorScrollController: harness.scroll,
              focusNode: harness.focus,
              editorStyle: const EditorStyle.mobile(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    harness.state.selection = Selection.single(
      path: [0],
      startOffset: 1,
      endOffset: 3,
    );
    await tester.pumpAndSettle();
    return harness;
  }
}

/// 触发[tester]中实际系统菜单的[label]，覆盖折叠菜单项使用的同一生产回调。
Future<void> _choose(WidgetTester tester, String label) async {
  final menu = tester.widget<AdaptiveTextSelectionToolbar>(
    find.byKey(const ValueKey('editor-selection-menu')),
  );
  menu.buttonItems!.singleWhere((item) => item.label == label).onPressed!();
  await tester.pumpAndSettle();
}

/// 验证通用菜单把复制与剪切交给宿主，且不会在委托后再次写剪贴板或删除正文。
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

  for (final cut in [false, true]) {
    testWidgets(
      'mobile ${cut ? 'cut' : 'copy'} delegates captured selection without fallback writes or deletion',
      (tester) async {
        final calls = <(Selection, bool)>[];
        final clipboardWrites = <Object?>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              clipboardWrites.add(call.arguments);
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
        final harness = await _MenuHarness.mount(tester, (
          selection, {
          required cut,
        }) async {
          calls.add((selection, cut));
          await AppFlowyClipboard.setData(text: '宿主生成的可读文本');
        });
        await _choose(tester, cut ? '剪切' : '复制');
        expect(calls, [
          (Selection.single(path: [0], startOffset: 1, endOffset: 3), cut),
        ]);
        expect(clipboardWrites, [
          {'text': '宿主生成的可读文本'},
        ]);
        expect(harness.state.document.first!.delta!.toPlainText(), '前目标后');
        expect(harness.state.undoManager.undoStack.isEmpty, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'mobile cut lets the delegate own deletion and one undo restores the range',
    (tester) async {
      late _MenuHarness harness;
      var calls = 0;
      harness = await _MenuHarness.mount(tester, (
        selection, {
        required cut,
      }) async {
        expect(cut, isTrue);
        calls++;
        await harness.state.deleteSelection(selection);
      });
      await _choose(tester, '剪切');
      expect(calls, 1);
      expect(harness.state.document.first!.delta!.toPlainText(), '前后');
      harness.state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(harness.state.document.first!.delta!.toPlainText(), '前目标后');
      expect(harness.state.undoManager.undoStack.isEmpty, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'a failed copy delegate preserves source and shows the menu error message',
    (tester) async {
      final harness = await _MenuHarness.mount(tester, (
        selection, {
        required cut,
      }) async {
        throw PlatformException(code: 'clipboard-unavailable');
      });
      await _choose(tester, '剪切');
      expect(harness.state.document.first!.delta!.toPlainText(), '前目标后');
      expect(harness.state.undoManager.undoStack.isEmpty, isTrue);
      expect(find.text('操作失败，请重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
