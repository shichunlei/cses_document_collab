import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../test/heading_typography_test.dart' as typography;
import '../test/mobile_selection_menu_test.dart' as selection_menu;

/// 在Android真机验证三项格式修复与划词菜单，全部使用隔离测试正文。
/// IME事件由测试连接注入；不初始化账号、原生协同文档或业务缓存。
/// 从Demo宿主以--keep-app-running驱动，结束后覆盖安装普通Demo。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    expect(Platform.isAndroid, isTrue, reason: '必须使用Android设备运行');
  });
  setUp(binding.testTextInput.register);
  tearDown(binding.testTextInput.unregister);

  // Reuse actual page rendering and menu assertions rather than a second oracle.
  typography.registerHeadingTypographyTests(useDeviceViewport: true);
  selection_menu.main();
  testWidgets('Android actual long press menu, link and inline formula', (
    tester,
  ) async {
    await selection_menu.verifyMobileSelectionMenuGestures(tester);
  });
  for (final replace in [false, true]) {
    testWidgets('Android active IME follows remote defaults replace=$replace', (
      tester,
    ) async {
      await _verifyRemoteDefaultsInput(tester, replace: replace);
    });
  }
}

/// 在借用 [tester] 的真实页面中更新空段默认格式；[replace] 为true替换，否则清除。
/// 验证原光标输入连接、输入结果与撤销，不接触持久化文档；创建者在退出时释放全部状态。
Future<void> _verifyRemoteDefaultsInput(
  WidgetTester tester, {
  required bool replace,
}) async {
  final changes = <List<CollabEditorBlock>>[];
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [
      CollabEditorBlock(
        id: 'remote-defaults',
        blockType: 'paragraph',
        text: '',
        paragraphStyle: CollabResource.fromValues({
          'textDefaults': {
            'a:bold': true,
            's:color': '#123456',
            't:px': 24,
            't:ff': 'courier',
            't:ls': .1,
          },
        }),
      ),
    ],
    onLocalBlocksChanged: changes.add,
  );
  final state = adapter.editorState;
  final controller = _ReviewController(state);
  try {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: CollaborativeEditorPage(collab: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.runtimeType.toString() == 'MobileSelectionServiceWidget',
      ),
      findsOneWidget,
    );
    final selected = state.updateSelectionWithReason(
      Selection.single(path: [0], startOffset: 0),
      reason: SelectionUpdateReason.uiEvent,
    );
    await tester.pump();
    await selected;
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
    expect(state.toggledStyle['t:px'], 24);
    await adapter.replaceFromRemote([
      CollabEditorBlock(
        id: 'remote-defaults',
        blockType: 'paragraph',
        text: '',
        paragraphStyle: replace
            ? CollabResource.fromValues({
                'textDefaults': {'a:italic': true, 't:fs': 1.5},
              })
            : null,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 200));
    expect(changes, isEmpty);
    expect(state.selection, Selection.single(path: [0], startOffset: 0));
    expect(tester.testTextInput.hasAnyClients, isTrue);
    for (final key in [
      AppFlowyRichTextKeys.bold,
      AppFlowyRichTextKeys.textColor,
      't:px',
      't:ff',
      't:ls',
    ]) {
      expect(state.toggledStyle[key], isNull, reason: key);
    }
    final editing = TextEditingValue.fromJSON(
      tester.testTextInput.editingState!,
    );
    final offset = editing.selection.extentOffset;
    tester.testTextInput.updateEditingValue(
      editing.copyWith(
        text: editing.text.replaceRange(offset, offset, '中文'),
        selection: TextSelection.collapsed(offset: offset + 2),
        composing: TextRange.empty,
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(adapter.blocks.single.text, '中文');
    if (replace) {
      expect(adapter.blocks.single.segments.single.bold, isFalse);
      expect(adapter.blocks.single.segments.single.italic, isTrue);
      expect(jsonDecode(adapter.blocks.single.segments.single.typography!), {
        't:fs': 1.5,
      });
    } else {
      expect(adapter.blocks.single.segments, isEmpty);
    }
    state.undoManager.undo();
    await tester.pumpAndSettle();
    expect(adapter.blocks.single.text, isEmpty);
    expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isNull);
    expect(tester.takeException(), isNull);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    adapter.dispose();
  }
}

/// 为真实页面提供隔离的已初始化编辑器，借用测试适配器，不连接持久化或账号。
class _ReviewController extends CollabController {
  /// [state] 由外部测试适配器拥有，本控制器释放时不关闭该借用状态。
  _ReviewController(this.state) : super.localDraft(databasePath: '/unused');

  /// 外部测试适配器拥有的正文编辑状态。
  final EditorState state;

  /// 返回隔离正文供页面挂载真实移动选择与输入服务。
  @override
  EditorState get editorState => state;

  /// 测试正文已就绪，页面不执行原生初始化。
  @override
  bool get initialized => true;

  /// 允许测试页面输入、格式操作和编辑/预览切换。
  @override
  bool get canEdit => true;

  /// 测试文档没有协同只读限制。
  @override
  String? get readOnlyReason => null;
}
