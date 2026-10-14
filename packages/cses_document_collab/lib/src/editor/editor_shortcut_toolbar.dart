import 'dart:async';

import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:cses_document_collab/src/editor/editor_media_source_sheet.dart';

import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/editor/stable_mobile_toolbar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

/// Mobile editor shell matching the keyboard toolbar in the supplied reference.
///
/// Only commands represented by the current collaborative schema are active.
/// Unsupported actions stay visible so the interaction model can be evaluated
/// without silently creating local-only nodes that Rust/Yrs cannot preserve.
class EditorShortcutToolbar extends StatefulWidget {
  const EditorShortcutToolbar({
    super.key,
    required this.editorState,
    required this.child,
  });

  final EditorState editorState;
  final Widget child;

  @override
  createState() => _EditorShortcutToolbarState();
}

/// 移动工具栏状态：拥有样式控制器和退格拦截器，借用编辑器及其键盘服务。
/// 首帧后注册拦截器，编辑器更换时迁移订阅，退出时注销，不释放外部 EditorState。
class _EditorShortcutToolbarState extends State<EditorShortcutToolbar> {
  late _InlineStyleController _inlineStyleController;

  /// 本状态拥有的无状态退格拦截器；注册到借用的键盘服务，退出前注销。
  late final CollabBlockBackspaceInterceptor _backspaceInterceptor;
  AppFlowyKeyboardService? _interceptedKeyboardService;
  int _emptyParagraphKeyboardRequestGeneration = 0;

  /// 创建所属控制器/拦截器并订阅选区，首帧服务挂载后注册；资源在 dispose 中成对释放。
  @override
  void initState() {
    super.initState();
    registerCsesRichTextAttributes();
    _inlineStyleController = _InlineStyleController(widget.editorState);
    _backspaceInterceptor = CollabBlockBackspaceInterceptor();
    widget.editorState.selectionNotifier.addListener(
      _onSelectionMayNeedEmptyParagraphKeyboard,
    );
    _registerBackspaceInterceptorAfterLayout();
  }

  /// [oldWidget] 提供旧编辑器；编辑器更换时先注销旧服务/选区监听并释放旧样式控制器，
  /// 再绑定当前编辑器。键盘服务和 EditorState 均由外部持有，不在此关闭。
  @override
  void didUpdateWidget(covariant EditorShortcutToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editorState != widget.editorState) {
      _unregisterBackspaceInterceptor();
      oldWidget.editorState.selectionNotifier.removeListener(
        _onSelectionMayNeedEmptyParagraphKeyboard,
      );
      _inlineStyleController.dispose();
      _inlineStyleController = _InlineStyleController(widget.editorState);
      widget.editorState.selectionNotifier.addListener(
        _onSelectionMayNeedEmptyParagraphKeyboard,
      );
      _registerBackspaceInterceptorAfterLayout();
    }
  }

  /// 注销借用服务上的退格拦截器及选区监听，释放所属样式控制器；外部编辑器保持有效。
  @override
  void dispose() {
    _unregisterBackspaceInterceptor();
    widget.editorState.selectionNotifier.removeListener(
      _onSelectionMayNeedEmptyParagraphKeyboard,
    );
    _inlineStyleController.dispose();
    super.dispose();
  }

  /// 在子编辑器首帧挂载服务后注册统一退格入口；已销毁或已注册则跳过，重复回调幂等。
  /// 不创建键盘服务，成功时保存借用引用供迁移/退出注销。
  void _registerBackspaceInterceptorAfterLayout() {
    // EditorShortcutToolbar is the parent of AppFlowyEditor, so its initState
    // runs before the child installs KeyboardService. At the first post-frame
    // callback the service is available and can safely accept the interceptor.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _interceptedKeyboardService != null) {
        return;
      }
      final keyboardService = widget.editorState.service.keyboardService;
      if (keyboardService == null) {
        return;
      }
      keyboardService.registerInterceptor(_backspaceInterceptor);
      _interceptedKeyboardService = keyboardService;
    });
  }

  /// 从借用服务移除本状态拥有的拦截器并清空引用；重复调用安全，不关闭服务。
  void _unregisterBackspaceInterceptor() {
    _interceptedKeyboardService?.unregisterInterceptor(_backspaceInterceptor);
    _interceptedKeyboardService = null;
  }

  void _onSelectionMayNeedEmptyParagraphKeyboard() {
    final requestGeneration = ++_emptyParagraphKeyboardRequestGeneration;
    final selection = widget.editorState.selection;
    if (defaultTargetPlatform != TargetPlatform.android ||
        selection == null ||
        !selection.isCollapsed ||
        widget
                .editorState
                .selectionExtraInfo?[selectionExtraInfoDoNotAttachTextService] ==
            true ||
        widget.editorState.selectionUpdateReason !=
            SelectionUpdateReason.uiEvent) {
      return;
    }
    final node = widget.editorState.getNodeAtPath(selection.start.path);
    if (node?.delta?.toPlainText().isNotEmpty != false) {
      return;
    }

    // AppFlowy's NonDeltaTextInputService caches only TextEditingValue, which
    // contains text and offsets but not a block path. Moving from one empty
    // paragraph to another therefore looks unchanged and `attach()` can skip
    // its normal platform `show()` call. Defer the workaround briefly so a
    // successful normal attach gets the first opportunity to update insets.
    unawaited(
      _showKeyboardForEmptyParagraphIfStillNeeded(selection, requestGeneration),
    );
  }

  Future<void> _showKeyboardForEmptyParagraphIfStillNeeded(
    Selection selection,
    int requestGeneration,
  ) async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted ||
        requestGeneration != _emptyParagraphKeyboardRequestGeneration ||
        widget.editorState.selection != selection ||
        widget
                .editorState
                .selectionExtraInfo?[selectionExtraInfoDoNotAttachTextService] ==
            true ||
        ModalRoute.of(context)?.isCurrent == false ||
        _editorKeyboardIsVisible(context)) {
      return;
    }

    final node = widget.editorState.getNodeAtPath(selection.start.path);
    if (node?.delta?.toPlainText().isNotEmpty != false) {
      return;
    }

    // Selection handling has already attached (or reused) AppFlowy's text
    // input connection and requested editor focus. Calling the platform show
    // method directly avoids attaching a second client and fixes precisely the
    // cached-empty-value branch where AppFlowy omitted that one method call.
    widget.editorState.service.keyboardService?.enable();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return widget.child;
    }
    return StableMobileToolbar(
      editorState: widget.editorState,
      toolbarHeight: 52,
      buttonHeight: 42,
      buttonSpacing: 6,
      itemOutlineColor: const Color(0xFFE5E7EB),
      primaryColor: const Color(0xFF2563EB),
      toolbarItems: [
        _addBlockToolbarItem,
        _blockStyleToolbarItem,
        _textDecorationToolbarItem(_inlineStyleController),
        _blockLayoutToolbarItem,
        _imageToolbarItem,
        _unsupportedToolbarItem(
          key: const ValueKey('editor-shortcut-mention'),
          icon: const Icon(Icons.alternate_email),
          label: '提及',
        ),
      ],
      child: widget.child,
    );
  }
}

class _InlineStyleController extends ChangeNotifier {
  _InlineStyleController(this.editorState) {
    editorState.selectionNotifier.addListener(_onSelectionChanged);
    // The toolbar can be mounted after the editor already owns a selection
    // (for example when returning from preview mode). Initialize immediately
    // instead of waiting for a second tap to emit another selection event.
    _onSelectionChanged();
  }

  // These are exactly the inline attributes exposed by the Aa menu. Reading a
  // fixed allow-list prevents unrelated delta metadata, such as links, from
  // silently becoming an IME style merely because the caret enters that text.
  static final _supportedAttributes = <String>[
    AppFlowyRichTextKeys.bold,
    AppFlowyRichTextKeys.italic,
    AppFlowyRichTextKeys.underline,
    AppFlowyRichTextKeys.strikethrough,
    AppFlowyRichTextKeys.code,
    AppFlowyRichTextKeys.textColor,
    AppFlowyRichTextKeys.backgroundColor,
    csesSuperscriptAttribute,
    csesSubscriptAttribute,
  ];

  final EditorState editorState;

  // A paragraph remains active even when `_activeStyles` is empty. This
  // distinction is important after a manual cancellation: subsequent typing
  // in the same paragraph must stay unformatted instead of re-reading the
  // styled character immediately before the caret and enabling it again.
  String? _activeNodeId;
  final Map<String, dynamic> _activeStyles = {};

  dynamic value(String attribute) => _activeStyles[attribute];

  void toggle(String attribute, {String? mutuallyExclusiveWith}) {
    final node = _selectedCollapsedNode();
    if (node == null) {
      return;
    }
    _activeNodeId = node.id;
    final next = _activeStyles[attribute] == true ? null : true;
    if (next == null) {
      _activeStyles.remove(attribute);
    } else {
      _activeStyles[attribute] = true;
    }
    editorState.updateToggledStyle(attribute, next);
    if (mutuallyExclusiveWith != null) {
      _activeStyles.remove(mutuallyExclusiveWith);
      editorState.updateToggledStyle(mutuallyExclusiveWith, null);
    }
    notifyListeners();
  }

  void setValue(String attribute, dynamic value) {
    final node = _selectedCollapsedNode();
    if (node == null) {
      return;
    }
    _activeNodeId = node.id;
    if (value == null) {
      _activeStyles.remove(attribute);
    } else {
      _activeStyles[attribute] = value;
    }
    editorState.updateToggledStyle(attribute, value);
    notifyListeners();
  }

  Node? _selectedCollapsedNode() {
    final selection = editorState.selection;
    if (selection == null || !selection.isCollapsed) {
      return null;
    }
    return editorState.getNodeAtPath(selection.start.path);
  }

  void clearAll() {
    if (_activeStyles.isEmpty) {
      return;
    }
    for (final attribute in _activeStyles.keys) {
      editorState.updateToggledStyle(attribute, null);
    }
    _activeStyles.clear();
    _activeNodeId = null;
    notifyListeners();
  }

  void _onSelectionChanged() {
    final selection = editorState.selection;
    if (selection == null) {
      _resetLocalState();
      return;
    }

    // Expanded selections calculate button state directly from the selected
    // Delta range. Dropping the collapsed-caret session here ensures that the
    // next tap initializes from its new caret location rather than stale data.
    if (!selection.isCollapsed) {
      _resetLocalState();
      return;
    }

    final startNode = editorState.getNodeAtPath(selection.start.path);
    if (startNode == null) {
      _resetLocalState();
      return;
    }

    if (startNode.id != _activeNodeId) {
      _initializeFromCaret(startNode, selection.start.offset);
      return;
    }

    // AppFlowy clears `toggledStyle` whenever the selection changes. Restore
    // the paragraph session after normal typing moves the caret forward.
    _applyToUpcomingInput();
    notifyListeners();
  }

  void _initializeFromCaret(Node node, int offset) {
    final attributes = _attributesAtCaret(node, offset);
    _activeNodeId = node.id;
    _activeStyles.clear();

    for (final attribute in _supportedAttributes) {
      final value = attributes?[attribute];
      final isEnabledBoolean = value == true;
      final isColor =
          (attribute == AppFlowyRichTextKeys.textColor ||
              attribute == AppFlowyRichTextKeys.backgroundColor) &&
          value is String;
      if (isEnabledBoolean || isColor) {
        _activeStyles[attribute] = value;
        editorState.updateToggledStyle(attribute, value);
      }
    }
    notifyListeners();
  }

  Attributes? _attributesAtCaret(Node node, int offset) {
    final operations = node.delta?.whereType<TextInsert>().toList();
    if (operations == null || operations.isEmpty) {
      return null;
    }

    // At paragraph start there is no character on the left, so use the first
    // character's run. At every other position the left character determines
    // the typing style, matching common rich-text editor caret semantics and
    // allowing typing at the end of a styled run to continue that style.
    final probeOffset = offset <= 0 ? 0 : offset - 1;
    var operationStart = 0;
    for (final operation in operations) {
      final operationEnd = operationStart + operation.length;
      if (probeOffset < operationEnd) {
        return operation.attributes;
      }
      operationStart = operationEnd;
    }

    // Defensive fallback for a stale offset beyond the current text length.
    // The final run is the closest valid source of caret formatting.
    return operations.last.attributes;
  }

  void _resetLocalState() {
    if (_activeNodeId == null && _activeStyles.isEmpty) {
      return;
    }
    _activeNodeId = null;
    _activeStyles.clear();
    notifyListeners();
  }

  void _applyToUpcomingInput() {
    for (final entry in _activeStyles.entries) {
      editorState.updateToggledStyle(entry.key, entry.value);
    }
  }

  @override
  void dispose() {
    editorState.selectionNotifier.removeListener(_onSelectionChanged);
    super.dispose();
  }
}

final _addBlockToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '添加块',
    child: KeyedSubtree(
      key: ValueKey('editor-shortcut-add'),
      child: Icon(Icons.add_circle_outline, size: 27),
    ),
  ),
  actionHandler: (context, editorState) {
    unawaited(showEditorAddBlockSheet(context, editorState));
  },
);

/// The compact keyboard toolbar exposes the same image insertion flow as the
/// exhaustive add sheet. Keeping both entry points on one function guarantees
/// identical URL validation, collaborative node shape and caret restoration.
final _imageToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '插入图片',
    child: KeyedSubtree(
      key: ValueKey('editor-shortcut-image'),
      child: Icon(Icons.image_outlined),
    ),
  ),
  actionHandler: (context, editorState) {
    unawaited(
      showEditorUrlBlockDialog(context, editorState, ImageBlockKeys.type),
    );
  },
);

MobileToolbarItem _textDecorationToolbarItem(
  _InlineStyleController inlineStyleController,
) => MobileToolbarItem.withMenu(
  itemIconBuilder: (context, editorState, isSelected) => KeyedSubtree(
    key: const ValueKey('editor-shortcut-inline-style'),
    child: textDecorationMobileToolbarItemV2.itemIconBuilder!(
      context,
      editorState,
      isSelected,
    )!,
  ),
  itemMenuBuilder: (_, editorState, service) => _InlineStyleMenu(
    editorState: editorState,
    inlineStyleController: inlineStyleController,
  ),
);

final _blockStyleToolbarItem = MobileToolbarItem.withMenu(
  itemIconBuilder: (context, editorState, service) => const KeyedSubtree(
    key: ValueKey('editor-shortcut-block-style'),
    child: Tooltip(
      message: '块类型',
      child: Text(
        'T',
        style: TextStyle(fontSize: 29, height: 1, fontWeight: FontWeight.w500),
      ),
    ),
  ),
  itemMenuBuilder: (_, editorState, service) =>
      _BlockStyleMenu(editorState: editorState),
);

/// 块布局菜单，借用 [EditorState] 显示对齐及三种列表共用缩进能力，不拥有编辑器资源。
class _BlockLayoutMenu extends StatefulWidget {
  /// [editorState] 为宿主持有的编辑器；菜单读取当前选区，交互期间不保存选区快照。
  const _BlockLayoutMenu({required this.editorState});

  /// 借用的编辑器，提供选区与事务；由宿主释放，菜单不关闭键盘或编辑器。
  final EditorState editorState;

  /// 创建仅管理菜单展示的状态；列表写入由共用事务负责。
  @override
  createState() => _BlockLayoutMenuState();
}

/// 根据当前选区展示可用操作；点击时重新校验，事务完成后在仍挂载且编辑器未更换时刷新。
class _BlockLayoutMenuState extends State<_BlockLayoutMenu> {
  String? _colorAttribute;

  Widget _buildBlockColors(List<Node> nodes) {
    final attribute = _colorAttribute!;
    final isBorder = attribute == csesBlockBorderColorAttribute;
    final prefix = isBorder
        ? 'editor-block-border-color'
        : 'editor-block-background-color';
    final colors = isBorder ? _textColors : _backgroundColors;
    final targets = nodes
        .where(
          (node) =>
              node.delta != null &&
              (!isBorder || node.type == QuoteBlockKeys.type),
        )
        .toList();
    final current = targets.isEmpty
        ? null
        : parseCollabBlockColor(targets.first.attributes[attribute] as String?);
    final uniform = targets.every(
      (n) =>
          parseCollabBlockColor(n.attributes[attribute] as String?) == current,
    );
    return ListView(
      key: ValueKey('$prefix-menu'),
      scrollDirection: Axis.horizontal,
      children: [
        _PopupIconButton(
          key: ValueKey('$prefix-back'),
          tooltip: '返回块布局',
          selected: false,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => setState(() => _colorAttribute = null),
        ),
        _PopupIconButton(
          key: ValueKey('$prefix-default'),
          tooltip: isBorder ? '默认线条颜色' : '清除块背景色',
          selected: uniform && current == null,
          icon: const Icon(Icons.format_color_reset),
          onPressed: () => _setBlockColor(null),
        ),
        for (final color in colors)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _PopupIconButton(
              key: ValueKey('$prefix-${color.name}'),
              tooltip: color.label,
              selected: uniform && current == color.color,
              icon: DecoratedBox(
                decoration: BoxDecoration(
                  color: color.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x22000000)),
                ),
                child: const SizedBox.square(dimension: 25),
              ),
              onPressed: () => _setBlockColor(color.color),
            ),
          ),
      ],
    );
  }

  Future<void> _setBlockColor(Color? color) async {
    final state = widget.editorState;
    final selection = state.selection;
    final attribute = _colorAttribute;
    if (state.isDisposed ||
        !state.editable ||
        selection == null ||
        attribute == null) {
      return;
    }
    final transaction = state.transaction;
    // CSS 值直接供桌面使用；透明度与文字高亮各自独立。
    final css = color == null
        ? null
        : 'rgba(${(color.r * 255).round()}, ${(color.g * 255).round()}, ${(color.b * 255).round()}, ${color.a})';
    for (final node in state.getNodesInSelection(selection)) {
      if (node.delta == null ||
          (attribute == csesBlockBorderColorAttribute &&
              node.type != QuoteBlockKeys.type)) {
        continue;
      }
      transaction.updateNode(node, {
        attribute: css,
        if (attribute == csesBlockBackgroundColorAttribute)
          blockComponentBackgroundColor: color?.toHex(),
      });
    }
    if (transaction.operations.isEmpty) return;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(
      transaction,
      withUpdateSelection: false,
      skipHistoryDebounce: true,
    );
    if (mounted && identical(widget.editorState, state)) setState(() {});
  }

  /// 使用 [context] 渲染布局按钮；能力判定为纯读取，0 级列表仍可减少缩进转段落。
  @override
  Widget build(BuildContext context) {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    if (_colorAttribute != null) return _buildBlockColors(nodes);
    final canOutdent = canChangeCollabListIndent(widget.editorState, -1);
    final canIncreaseIndent = canChangeCollabListIndent(widget.editorState, 1);

    return ListView(
      key: const ValueKey('editor-block-layout-menu'),
      scrollDirection: Axis.horizontal,
      children: [
        _PopupIconButton(
          key: const ValueKey('editor-block-outdent'),
          tooltip: '减少缩进',
          enabled: canOutdent,
          selected: false,
          icon: const Icon(Icons.format_indent_decrease, size: 28),
          onPressed: () => _changeIndent(-1),
        ),
        const SizedBox(width: 5),
        _PopupIconButton(
          key: const ValueKey('editor-block-indent'),
          tooltip: '增加缩进',
          enabled: canIncreaseIndent,
          selected: false,
          icon: const Icon(Icons.format_indent_increase, size: 28),
          onPressed: () => _changeIndent(1),
        ),
        const SizedBox(width: 10),
        for (final option in const [
          ('left', '左对齐', Icons.format_align_left),
          ('center', '居中', Icons.format_align_center),
          ('right', '右对齐', Icons.format_align_right),
          ('justify', '两端对齐', Icons.format_align_justify),
          ('distributed', '分散对齐', Icons.space_bar),
        ]) ...[
          _PopupIconButton(
            key: ValueKey('editor-block-align-${option.$1}'),
            tooltip: option.$2,
            enabled:
                !const {'justify', 'distributed'}.contains(option.$1) ||
                nodes.every((n) => n.delta != null),
            selected:
                nodes.isNotEmpty &&
                nodes.every((node) => _alignmentOf(node) == option.$1),
            icon: Icon(option.$3, size: 28),
            onPressed: () => _setAlignment(option.$1),
          ),
          const SizedBox(width: 5),
        ],
        _PopupIconButton(
          key: const ValueKey('editor-block-background-color'),
          tooltip: '块背景色',
          enabled: nodes.any((n) => n.delta != null),
          selected: false,
          icon: const Icon(Icons.format_color_fill, size: 28),
          onPressed: () => setState(
            () => _colorAttribute = csesBlockBackgroundColorAttribute,
          ),
        ),
        if (nodes.any((n) => n.type == QuoteBlockKeys.type))
          _PopupIconButton(
            key: const ValueKey('editor-block-border-color'),
            tooltip: '左侧线条颜色',
            selected: false,
            icon: const Icon(Icons.border_left, size: 28),
            onPressed: () =>
                setState(() => _colorAttribute = csesBlockBorderColorAttribute),
          ),
      ],
    );
  }

  /// 读取借用 [node] 的展示对齐方式；未知/缺失值回退 left，无副作用。
  String _alignmentOf(Node node) {
    final value = node.attributes[blockComponentAlign];
    return const {
          'left',
          'center',
          'right',
          'justify',
          'distributed',
        }.contains(value)
        ? value as String
        : 'left';
  }

  /// 将 [delta]（-1/+1）应用到点击时的当前选区；复用整组选区一个事务及原光标恢复。
  /// 不缓存 build 时选区，失效/只读或上限条件不执行。等待事务完成后检查 mounted 和编辑器
  /// 身份再刷新；非预期异常保留错误/堆栈上报 Log.e，并交 FlutterError，不重复用户提示。
  Future<void> _changeIndent(int delta) async {
    final state = widget.editorState;
    try {
      await changeCollabListIndent(state, delta);
      if (mounted && identical(widget.editorState, state)) {
        setState(() {});
      }
    } catch (error, stackTrace) {
      CollabDiagnostics.report(
        '文档列表缩进失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DocCollab',
          context: ErrorDescription('changing collaborative list indentation'),
        ),
      );
    }
  }

  Future<void> _setAlignment(String alignment) async {
    final state = widget.editorState;
    final selection = state.selection;
    if (state.isDisposed || !state.editable || selection == null) return;
    final nodes = state.getNodesInSelection(selection);
    if (const {'justify', 'distributed'}.contains(alignment) &&
        nodes.any((n) => n.delta == null)) {
      return;
    }
    final transaction = state.transaction;
    for (final node in nodes) {
      if (node.attributes[blockComponentAlign] == alignment) continue;
      transaction.add(
        UpdateOperation(
          node.path,
          {blockComponentAlign: alignment},
          {blockComponentAlign: node.attributes[blockComponentAlign]},
        ),
      );
    }
    if (transaction.operations.isEmpty) return;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(
      transaction,
      withUpdateSelection: false,
      skipHistoryDebounce: true,
    );
    if (mounted && identical(widget.editorState, state)) setState(() {});
  }
}

final _blockLayoutToolbarItem = MobileToolbarItem.withMenu(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '对齐与缩进',
    child: KeyedSubtree(
      key: ValueKey('editor-shortcut-block-layout'),
      child: Icon(Icons.format_align_left, size: 27),
    ),
  ),
  itemMenuBuilder: (_, editorState, service) =>
      _BlockLayoutMenu(editorState: editorState),
);

class _BlockStyleMenu extends StatefulWidget {
  const _BlockStyleMenu({required this.editorState});

  final EditorState editorState;

  @override
  State<_BlockStyleMenu> createState() => _BlockStyleMenuState();
}

class _BlockStyleMenuState extends State<_BlockStyleMenu> {
  /// 类型命令执行期间拒绝重复提交；所有退出路径均在 finally 恢复，不持有外部资源。
  bool _applyingStyle = false;
  // H1-H3 are the initial choices. Selecting H3 reveals H4, and each
  // subsequent highest visible heading reveals exactly one more level.
  int _maxHeadingLevel = 3;
  String? _activeNodeId;

  static const _paragraphStyle = _BlockStyleAction(
    blockType: ParagraphBlockKeys.type,
    label: '正文',
    text: 'T',
  );

  static const _blockStyles = <_BlockStyleAction>[
    _BlockStyleAction(
      blockType: NumberedListBlockKeys.type,
      label: '有序列表',
      icon: Icons.format_list_numbered,
    ),
    _BlockStyleAction(
      blockType: BulletedListBlockKeys.type,
      label: '无序列表',
      icon: Icons.format_list_bulleted,
    ),
    _BlockStyleAction(
      blockType: TodoListBlockKeys.type,
      label: '任务列表',
      icon: Icons.check_box_outlined,
    ),
    _BlockStyleAction(blockType: 'code', label: '代码块', icon: Icons.data_object),
    _BlockStyleAction(
      blockType: QuoteBlockKeys.type,
      label: '引用块',
      icon: Icons.format_quote,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _activeNodeId = _selectedNodeId();
    _maxHeadingLevel = _headingLimitForSelection();
    widget.editorState.selectionNotifier.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(covariant _BlockStyleMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editorState != widget.editorState) {
      oldWidget.editorState.selectionNotifier.removeListener(
        _onSelectionChanged,
      );
      widget.editorState.selectionNotifier.addListener(_onSelectionChanged);
      _activeNodeId = _selectedNodeId();
      _maxHeadingLevel = _headingLimitForSelection();
    }
  }

  @override
  void dispose() {
    widget.editorState.selectionNotifier.removeListener(_onSelectionChanged);
    super.dispose();
  }

  void _onSelectionChanged() {
    final nextNodeId = _selectedNodeId();
    if (nextNodeId == _activeNodeId) {
      return;
    }
    _activeNodeId = nextNodeId;
    if (mounted) {
      // Heading disclosure is scoped to the selected paragraph. A normal block
      // starts at H1-H3, while entering an existing H4-H9 block must expose its
      // current level so the selected state is visible in the T menu.
      setState(() => _maxHeadingLevel = _headingLimitForSelection());
    }
  }

  String? _selectedNodeId() {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return null;
    }
    return widget.editorState.getNodeAtPath(selection.start.path)?.id;
  }

  int _headingLimitForSelection() {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return 3;
    }
    final node = widget.editorState.getNodeAtPath(selection.start.path);
    if (node?.type != HeadingBlockKeys.type) {
      return 3;
    }

    final storedLevel = node?.attributes[HeadingBlockKeys.level];
    final level = storedLevel is int ? storedLevel.clamp(1, 9) : 1;
    if (level < 3) {
      return 3;
    }

    // H3 is the first progressive boundary: entering an existing H3 exposes
    // H4 immediately. H4-H8 follow the same Hn/H(n+1) rule, while H9 is the
    // schema maximum and therefore exposes only through H9.
    return math.min(level + 1, 9);
  }

  /// 为借用的 [context] 构建类型菜单；高亮当前起点类型，按钮在点击时读取最新选区。
  /// 构建过程无编辑副作用，列表命令由统一事务执行，Heading 选项按当前披露上限显示。
  @override
  Widget build(BuildContext context) {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }
    final node = widget.editorState.getNodeAtPath(selection.start.path);
    final styles = <_BlockStyleAction>[
      _paragraphStyle,
      for (var level = 1; level <= _maxHeadingLevel; level += 1)
        _BlockStyleAction(
          blockType: HeadingBlockKeys.type,
          headingLevel: level,
          label: '$level 级标题',
          text: 'H${_subscriptDigit(level)}',
        ),
      ..._blockStyles,
    ];

    return ListView.separated(
      key: const ValueKey('editor-block-style-menu'),
      scrollDirection: Axis.horizontal,
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
      itemCount: styles.length,
      separatorBuilder: (_, _) => const SizedBox(width: 4),
      itemBuilder: (context, index) {
        final style = styles[index];
        final selected = node != null && style.matches(node);
        return _PopupIconButton(
          key: ValueKey(
            'editor-block-${style.blockType}-${style.headingLevel ?? 0}',
          ),
          tooltip: style.label,
          selected: selected,
          icon: style.icon == null
              ? Text(
                  style.text!,
                  style: const TextStyle(fontSize: 26, height: 1),
                )
              : Icon(style.icon, size: 27),
          onPressed: () => _apply(style),
        );
      },
    );
  }

  /// 将 [style] 应用于点击时的当前选区；列表互换复用统一事务，保留层级、格式、勾选规则和焦点。
  /// 固定标题、只读/销毁、无选区以及执行中的重复命令不执行；列表与非列表混选不部分切换。
  /// 借用 EditorState，await 后检查菜单仍挂载且编辑器未更换，避免迟到刷新。失败由本边界
  /// 记录原始异常和堆栈并交给 Flutter 错误报告；Future 在事务与菜单刷新结束后完成。
  Future<void> _apply(_BlockStyleAction style) async {
    final state = widget.editorState;
    final selection = state.selection;
    if (_applyingStyle ||
        state.isDisposed ||
        !state.editable ||
        selection == null) {
      return;
    }
    final nodes = state.getNodesInSelection(selection);
    if (nodes.isEmpty ||
        nodes.any(
          (node) =>
              node.type == csesDocumentTitleBlockType ||
              node.type == csesCalloutBlockType,
        )) {
      return;
    }
    _applyingStyle = true;
    try {
      const listTypes = {'numbered_list', 'bulleted_list', 'todo_list'};
      if (listTypes.contains(style.blockType) &&
          nodes.any((node) => listTypes.contains(node.type))) {
        await changeCollabListType(state, style.blockType);
      } else {
        await state.formatNode(
          selection,
          (node) => _convertedNode(node, style.blockType, style.headingLevel),
        );
      }
      if (!mounted || widget.editorState != state || state.isDisposed) {
        return;
      }
      final level = style.headingLevel;
      setState(() {
        if (level != null && level >= 3 && level < 9) {
          _maxHeadingLevel = math.max(_maxHeadingLevel, level + 1);
        } else if (level == null || level < 3) {
          _maxHeadingLevel = 3;
        }
      });
    } catch (error, stackTrace) {
      CollabDiagnostics.report(
        '文档列表类型切换失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DocCollab',
          context: ErrorDescription('切换文档块类型'),
        ),
      );
    } finally {
      _applyingStyle = false;
    }
  }
}

String _subscriptDigit(int value) => const {
  1: '₁',
  2: '₂',
  3: '₃',
  4: '₄',
  5: '₅',
  6: '₆',
  7: '₇',
  8: '₈',
  9: '₉',
}[value]!;

class _BlockStyleAction {
  const _BlockStyleAction({
    required this.blockType,
    required this.label,
    this.headingLevel,
    this.text,
    this.icon,
  }) : assert(text != null || icon != null);

  final String blockType;
  final int? headingLevel;
  final String label;
  final String? text;
  final IconData? icon;

  bool matches(Node node) {
    if (node.type != blockType) {
      return false;
    }
    return blockType != HeadingBlockKeys.type ||
        node.attributes[HeadingBlockKeys.level] == headingLevel;
  }
}

class _InlineStyleMenu extends StatefulWidget {
  const _InlineStyleMenu({
    required this.editorState,
    required this.inlineStyleController,
  });

  final EditorState editorState;
  final _InlineStyleController inlineStyleController;

  @override
  createState() => _InlineStyleMenuState();
}

class _InlineStyleMenuState extends State<_InlineStyleMenu> {
  // The two color entries are inserted after the five boolean text styles.
  // Keeping explicit indices makes the visual order stable while `_styles`
  // remains responsible only for on/off attributes such as bold and code.
  static const _textColorButtonIndex = 5;
  static const _backgroundColorButtonIndex = 6;

  // A single picker replaces the normal Aa row. The target records whether a
  // palette choice updates the glyph color (`font_color`) or the inline
  // highlight behind the glyph (`bg_color`).
  _InlineColorTarget? _colorPicker;

  static final _styles = <_InlineStyleAction>[
    _InlineStyleAction(
      key: AppFlowyRichTextKeys.bold,
      label: '加粗',
      icon: Icons.format_bold,
    ),
    _InlineStyleAction(
      key: AppFlowyRichTextKeys.italic,
      label: '斜体',
      icon: Icons.format_italic,
    ),
    _InlineStyleAction(
      key: AppFlowyRichTextKeys.underline,
      label: '下划线',
      icon: Icons.format_underlined,
    ),
    _InlineStyleAction(
      key: AppFlowyRichTextKeys.strikethrough,
      label: '删除线',
      icon: Icons.format_strikethrough,
    ),
    _InlineStyleAction(
      key: AppFlowyRichTextKeys.code,
      label: '行内代码',
      icon: Icons.code,
    ),
    _InlineStyleAction(
      key: csesSuperscriptAttribute,
      label: '上标',
      icon: Icons.superscript,
    ),
    _InlineStyleAction(
      key: csesSubscriptAttribute,
      label: '下标',
      icon: Icons.subscript,
    ),
  ];

  @override
  void initState() {
    super.initState();
    widget.inlineStyleController.addListener(_onInlineStyleChanged);
  }

  @override
  void didUpdateWidget(covariant _InlineStyleMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inlineStyleController != widget.inlineStyleController) {
      oldWidget.inlineStyleController.removeListener(_onInlineStyleChanged);
      widget.inlineStyleController.addListener(_onInlineStyleChanged);
    }
  }

  @override
  void dispose() {
    widget.inlineStyleController.removeListener(_onInlineStyleChanged);
    super.dispose();
  }

  void _onInlineStyleChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }

    final colorPicker = _colorPicker;
    if (colorPicker != null) {
      return _buildColorPicker(selection, colorPicker);
    }

    final currentTextColor = _currentColor(
      selection,
      AppFlowyRichTextKeys.textColor,
    );
    final currentBackgroundColor = _currentColor(
      selection,
      AppFlowyRichTextKeys.backgroundColor,
    );

    return ListView.separated(
      key: const ValueKey('editor-inline-style-menu'),
      scrollDirection: Axis.horizontal,
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
      itemCount: _styles.length + 2,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, index) {
        if (index == _textColorButtonIndex) {
          return _PopupIconButton(
            key: const ValueKey('editor-inline-text-color'),
            tooltip: '文字颜色',
            selected: currentTextColor != null,
            icon: Icon(
              Icons.format_color_text,
              key: const ValueKey('editor-inline-text-color-icon'),
              size: 28,
              color: _colorForValue(currentTextColor, _textColors),
            ),
            onPressed: () =>
                setState(() => _colorPicker = _InlineColorTarget.text),
          );
        }
        if (index == _backgroundColorButtonIndex) {
          return _PopupIconButton(
            key: const ValueKey('editor-inline-background-color'),
            tooltip: '文字背景颜色',
            selected: currentBackgroundColor != null,
            icon: Icon(
              Icons.format_color_fill,
              key: const ValueKey('editor-inline-background-color-icon'),
              size: 28,
              color: _colorForValue(currentBackgroundColor, _backgroundColors),
            ),
            onPressed: () =>
                setState(() => _colorPicker = _InlineColorTarget.background),
          );
        }
        final style =
            _styles[index < _textColorButtonIndex ? index : index - 2];
        final key = switch (style.key) {
          csesSuperscriptAttribute => 'editor-inline-superscript',
          csesSubscriptAttribute => 'editor-inline-subscript',
          _ => 'editor-inline-${style.key}',
        };
        return _PopupIconButton(
          key: ValueKey(key),
          tooltip: style.label,
          selected: _isSelected(selection, style.key),
          icon: Icon(style.icon, size: 28),
          onPressed: () => _toggleStyle(selection, style.key),
        );
      },
    );
  }

  Widget _buildColorPicker(Selection selection, _InlineColorTarget target) {
    // AppFlowy uses separate delta attributes for foreground and background
    // colors. The shared picker keeps their interaction identical while the
    // key prefix leaves both flows independently addressable in widget tests.
    final isBackground = target == _InlineColorTarget.background;
    final attribute = isBackground
        ? AppFlowyRichTextKeys.backgroundColor
        : AppFlowyRichTextKeys.textColor;
    final prefix = isBackground
        ? 'editor-background-color'
        : 'editor-text-color';
    final options = isBackground ? _backgroundColors : _textColors;
    final currentColor = _currentColor(selection, attribute);
    return ListView(
      key: ValueKey('$prefix-menu'),
      scrollDirection: Axis.horizontal,
      children: [
        _PopupIconButton(
          key: ValueKey('$prefix-back'),
          tooltip: '返回格式',
          selected: false,
          icon: const Icon(Icons.arrow_back, size: 25),
          onPressed: () => setState(() => _colorPicker = null),
        ),
        const SizedBox(width: 6),
        _PopupIconButton(
          key: ValueKey('$prefix-default'),
          tooltip: isBackground ? '清除背景色' : '默认颜色',
          selected: currentColor == null,
          icon: const Icon(Icons.format_color_reset, size: 25),
          onPressed: () => _applyColor(selection, attribute, null),
        ),
        const SizedBox(width: 6),
        ...options.map(
          (option) => Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _PopupIconButton(
              key: ValueKey('$prefix-${option.name}'),
              tooltip: option.label,
              selected: currentColor == option.value,
              icon: DecoratedBox(
                decoration: BoxDecoration(
                  color: option.color,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x22000000)),
                ),
                child: const SizedBox.square(dimension: 25),
              ),
              onPressed: () => _applyColor(selection, attribute, option.value),
            ),
          ),
        ),
      ],
    );
  }

  String? _currentColor(Selection selection, String attribute) {
    // A collapsed selection has no characters to inspect, so its value comes
    // from the controller that owns formatting for subsequent IME input.
    if (selection.isCollapsed) {
      return widget.inlineStyleController.value(attribute) as String?;
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    String? color;
    var initialized = false;
    for (final node in nodes) {
      final delta = node.delta;
      if (delta == null) {
        continue;
      }
      final start = node == nodes.first ? selection.startIndex : 0;
      final end = node == nodes.last ? selection.endIndex : delta.length;
      final sliced = delta.slice(start, end);
      for (final operation in sliced) {
        final value = operation.attributes?[attribute];
        final next = value is String ? value : null;
        if (!initialized) {
          color = next;
          initialized = true;
        } else if (color != next) {
          // A mixed-color range has no single representative palette value.
          // Returning null intentionally leaves every color chip unselected.
          return null;
        }
      }
    }
    return color;
  }

  Future<void> _applyColor(
    Selection selection,
    String attribute,
    String? color,
  ) async {
    // Collapsed selections update `toggledStyle`, which AppFlowy's IME copies
    // onto newly typed text. Expanded selections format the existing delta
    // directly. Passing null removes the attribute and restores the default.
    if (selection.isCollapsed) {
      widget.inlineStyleController.setValue(attribute, color);
    } else {
      widget.inlineStyleController.clearAll();
      await widget.editorState.formatDelta(selection, {attribute: color});
    }
    if (mounted) {
      setState(() {});
    }
  }

  bool _isSelected(Selection selection, String attribute) {
    if (selection.isCollapsed) {
      return widget.inlineStyleController.value(attribute) == true;
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    return nodes.isNotEmpty &&
        nodes.allSatisfyInSelection(
          selection,
          (delta) => delta.everyAttributes(
            (attributes) => attributes[attribute] == true,
          ),
        );
  }

  Future<void> _toggleStyle(Selection selection, String attribute) async {
    final isScript =
        attribute == csesSuperscriptAttribute ||
        attribute == csesSubscriptAttribute;
    if (selection.isCollapsed) {
      final other = attribute == csesSuperscriptAttribute
          ? csesSubscriptAttribute
          : attribute == csesSubscriptAttribute
          ? csesSuperscriptAttribute
          : null;
      widget.inlineStyleController.toggle(
        attribute,
        mutuallyExclusiveWith: other,
      );
    } else {
      widget.inlineStyleController.clearAll();
      final other = attribute == csesSuperscriptAttribute
          ? csesSubscriptAttribute
          : csesSuperscriptAttribute;
      final next = !_isSelected(selection, attribute);
      if (!isScript) {
        await widget.editorState.toggleAttribute(
          attribute,
          selection: selection,
        );
      } else {
        await widget.editorState.formatDelta(selection, {
          other: null,
          attribute: next ? true : null,
        });
      }
    }
    if (mounted) {
      setState(() {});
    }
  }
}

enum _InlineColorTarget { text, background }

const _textColors = <_InlineColorOption>[
  _InlineColorOption('gray', '灰色', '0xff9e9e9e', Color(0xFF9E9E9E)),
  _InlineColorOption('brown', '棕色', '0xff795548', Color(0xFF795548)),
  _InlineColorOption('yellow', '黄色', '0xffffc107', Color(0xFFFFC107)),
  _InlineColorOption('green', '绿色', '0xff4caf50', Color(0xFF4CAF50)),
  _InlineColorOption('blue', '蓝色', '0xff2196f3', Color(0xFF2196F3)),
  _InlineColorOption('purple', '紫色', '0xff9c27b0', Color(0xFF9C27B0)),
  _InlineColorOption('red', '红色', '0xfff44336', Color(0xFFF44336)),
];

const _backgroundColors = <_InlineColorOption>[
  // Background colors use 0x4D alpha (30%). This produces a readable
  // highlighter effect without obscuring either dark or custom-colored text.
  _InlineColorOption('gray', '灰色背景', '0x4d9e9e9e', Color(0x4D9E9E9E)),
  _InlineColorOption('brown', '棕色背景', '0x4d795548', Color(0x4D795548)),
  _InlineColorOption('yellow', '黄色背景', '0x4dffc107', Color(0x4DFFC107)),
  _InlineColorOption('green', '绿色背景', '0x4d4caf50', Color(0x4D4CAF50)),
  _InlineColorOption('blue', '蓝色背景', '0x4d2196f3', Color(0x4D2196F3)),
  _InlineColorOption('purple', '紫色背景', '0x4d9c27b0', Color(0x4D9C27B0)),
  _InlineColorOption('red', '红色背景', '0x4df44336', Color(0x4DF44336)),
];

Color? _colorForValue(String? value, List<_InlineColorOption> options) {
  if (value == null) {
    return null;
  }
  for (final option in options) {
    if (option.value == value) {
      return option.color;
    }
  }
  return null;
}

class _InlineColorOption {
  const _InlineColorOption(this.name, this.label, this.value, this.color);

  final String name;
  final String label;
  final String value;
  final Color color;
}

class _PopupIconButton extends StatelessWidget {
  const _PopupIconButton({
    super.key,
    required this.tooltip,
    required this.selected,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
  });

  final String tooltip;
  final bool selected;
  final Widget icon;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Material(
          color: selected ? const Color(0xFFE6EEFF) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: enabled ? onPressed : null,
            child: SizedBox(width: 48, height: 48, child: Center(child: icon)),
          ),
        ),
      ),
    );
  }
}

class _InlineStyleAction {
  const _InlineStyleAction({
    required this.key,
    required this.label,
    required this.icon,
  });

  final String key;
  final String label;
  final IconData icon;
}

MobileToolbarItem _unsupportedToolbarItem({
  required Key key,
  required Widget icon,
  required String label,
}) {
  return MobileToolbarItem.action(
    itemIconBuilder: (_, _, _) => Tooltip(
      message: '$label（后续阶段）',
      child: KeyedSubtree(key: key, child: icon),
    ),
    actionHandler: (context, _) => _showUnsupportedMessage(context, label),
  );
}

void _showUnsupportedMessage(BuildContext context, String label) {
  _showToolbarMessage(context, '$label 尚未进入当前 Rust/Yrs 协同 Schema');
}

void _showToolbarMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
}

/// The saved selection is independent of focus and survives block reordering.
/// Both endpoints are retained so cancellation also restores expanded ranges.
class _EditorSelectionBookmark {
  _EditorSelectionBookmark(EditorState state, Selection selection)
    : startId = _idAt(state, selection.start),
      endId = _idAt(state, selection.end),
      startOffset = selection.start.offset,
      endOffset = selection.end.offset;

  final String? startId;
  final String? endId;
  final int startOffset;
  final int endOffset;

  static String? _idAt(EditorState state, Position point) {
    final node = state.getNodeAtPath(point.path);
    return node == null ? null : _mediaTargetId(node);
  }

  Position? _resolvePoint(EditorState state, String? id, int offset) {
    final node = id == null ? null : _findMediaTarget(state, id);
    if (node == null) return null;
    return Position(
      path: node.path,
      offset: offset.clamp(0, node.delta?.length ?? 0),
    );
  }

  Selection? resolve(EditorState state) {
    if (state.isDisposed || !state.editable) return null;
    final start = _resolvePoint(state, startId, startOffset);
    final end = _resolvePoint(state, endId, endOffset);
    if (start == null || end == null) return null;
    return Selection(start: start, end: end);
  }
}

/// Owns one entire modal flow, including a nested source/file chooser.
/// Never use the live editor selection as the modal's insertion bookmark.
class _EditorModalSession {
  _EditorModalSession(this.state)
    : bookmark = state.selection == null
          ? null
          : _EditorSelectionBookmark(state, state.selection!),
      previousExtraInfo = state.selectionExtraInfo == null
          ? null
          : Map<Object?, Object?>.from(state.selectionExtraInfo!),
      previousStyle = Map<String, dynamic>.from(state.toggledStyle) {
    state.selectionExtraInfo = {
      ...?previousExtraInfo,
      selectionExtraInfoDisableMobileToolbarKey: true,
      selectionExtraInfoDoNotAttachTextService: true,
    };
    state.selection = null;
    state.service.keyboardService
      ?..closeKeyboard()
      ..disableShortcuts()
      ..disable(disposition: UnfocusDisposition.scope);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  final EditorState state;
  final _EditorSelectionBookmark? bookmark;
  final Map<Object?, Object?>? previousExtraInfo;
  final Map<String, dynamic> previousStyle;

  Future<void> finish(
    BuildContext? context,
    Selection? appliedSelection,
  ) async {
    if (state.isDisposed) return;
    state.selectionExtraInfo = previousExtraInfo;
    state.service.keyboardService?.enableShortcuts();
    if (context == null || !_canRestoreEditorFocus(context, state)) return;
    final selection = appliedSelection ?? bookmark?.resolve(state);
    // A deleted anchor must not silently resolve to a different block.
    if (selection == null) return;
    await _restoreEditorCaretAndKeyboard(
      context,
      state,
      selection,
      extraInfo: previousExtraInfo,
    );
    if (!state.isDisposed &&
        appliedSelection == null &&
        state.selection == selection) {
      for (final entry in previousStyle.entries) {
        state.updateToggledStyle(entry.key, entry.value);
      }
    }
  }
}

Future<void> showEditorAddBlockSheet(
  BuildContext context,
  EditorState editorState,
) async {
  if (editorState.isDisposed || !editorState.editable) return;
  if (editorState.selection == null) {
    _showToolbarMessage(context, '请先把光标放入正文');
    return;
  }
  final session = _EditorModalSession(editorState);
  Selection? appliedSelection;
  ModalRoute<Selection>? route;
  try {
    appliedSelection = await showModalBottomSheet<Selection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      requestFocus: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        route = ModalRoute.of<Selection>(context);
        return _AddBlockSheet(
          editorState: editorState,
          bookmark: session.bookmark!,
        );
      },
    );
    await route?.completed;
  } finally {
    await session.finish(context.mounted ? context : null, appliedSelection);
  }
}

/// Opens the mobile source sheet with a separate insertion bookmark.
Future<void> showEditorUrlBlockDialog(
  BuildContext context,
  EditorState editorState,
  String blockType, {
  EditorMediaUploadService? service,
}) async {
  if (editorState.isDisposed || !editorState.editable) return;
  if (editorState.selection == null) {
    _showToolbarMessage(context, '请先把光标放入正文');
    return;
  }
  final session = _EditorModalSession(editorState);
  Selection? nextSelection;
  try {
    final source = await showEditorMediaSourceSheet(
      context,
      blockType: blockType,
      service: service,
      canEdit: () => !editorState.isDisposed && editorState.editable,
    );
    if (source == null || !context.mounted) return;
    final current = session.bookmark?.resolve(editorState);
    nextSelection = current == null
        ? null
        : await applyUrlBlockShortcut(
            editorState,
            current,
            blockType,
            source.url,
            mediaSource: source,
          );
    if (context.mounted && nextSelection == null) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
    }
  } finally {
    await session.finish(context.mounted ? context : null, nextSelection);
  }
}

String _mediaTargetId(Node node) =>
    node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute]
        as String? ??
    node.id;

Node? _findMediaTarget(EditorState state, String id) {
  if (state.isDisposed) return null;
  Node? visit(Node node) {
    if (_mediaTargetId(node) == id) return node;
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  return visit(state.document.root);
}

/// Adds, replaces or removes the cover, restoring any prior body selection.
Future<void> showEditorDocumentCoverDialog(
  BuildContext context,
  EditorState editorState,
  Node coverNode,
) async {
  if (editorState.isDisposed || !editorState.editable) return;
  final currentUrl =
      coverNode.attributes[csesEmbedUrlAttribute] as String? ?? '';
  final id = _mediaTargetId(coverNode);
  final session = _EditorModalSession(editorState);
  try {
    final source = await showEditorMediaSourceSheet(
      context,
      blockType: csesDocumentCoverBlockType,
      initialValue: currentUrl,
      allowRemove: currentUrl.isNotEmpty,
      canEdit: () => !editorState.isDisposed && editorState.editable,
    );
    if (source == null ||
        !context.mounted ||
        editorState.isDisposed ||
        !editorState.editable) {
      return;
    }
    final latestNode = _findMediaTarget(editorState, id);
    if (latestNode == null || latestNode.type != csesDocumentCoverBlockType) {
      _showToolbarMessage(context, '封面已被远端修改，请重试');
      return;
    }
    final transaction = editorState.transaction
      ..updateNode(latestNode, {csesEmbedUrlAttribute: source.url});
    await editorState.apply(transaction);
  } finally {
    await session.finish(context.mounted ? context : null, null);
  }
}

bool _canRestoreEditorFocus(BuildContext context, EditorState state) =>
    context.mounted &&
    !state.isDisposed &&
    state.editable &&
    ModalRoute.of(context)?.isCurrent != false;

/// Restores an AppFlowy text-input client after a dialog or bottom sheet.
///
/// URL-backed insertion deliberately leaves the transaction selection null so
/// no editor input client opens underneath a still-visible modal. Once this
/// method runs, the modal route is gone; it waits for the new paragraph widget
/// to register, then emits one UI selection that both attaches AppFlowy's text
/// input service and requests focus.
Future<void> _restoreEditorCaretAndKeyboard(
  BuildContext context,
  EditorState editorState,
  Selection selection, {
  Map<Object?, Object?>? extraInfo,
}) async {
  // The document mutation and modal dismissal can finish in the same frame.
  // Waiting for the target node's widget registration prevents the input
  // service from attaching before the paragraph has a render/selectable state.
  await _waitForEditableSelectionTarget(editorState, selection);
  if (!context.mounted || !_canRestoreEditorFocus(context, editorState)) return;

  // Re-emitting a UI selection is sufficient: KeyboardService's selection
  // listener attaches the text input service and requests editor focus. Do not
  // call `enable` and `enableKeyBoard` as well, because that produces multiple
  // simultaneous Android `showSoftInput` requests.
  await editorState.updateSelectionWithReason(
    selection,
    reason: SelectionUpdateReason.uiEvent,
    extraInfo: extraInfo,
  );
  if (!context.mounted) {
    return;
  }

  if (defaultTargetPlatform != TargetPlatform.android) {
    return;
  }

  // Keep one guarded recovery for device keyboards that ignore the first show
  // request. Closing the AppFlowy connection resets its cached editing value;
  // re-emitting the same selection then performs a clean attach instead of
  // stacking another show request on an existing connection.
  await Future<void>.delayed(const Duration(milliseconds: 360));
  if (!context.mounted ||
      !_canRestoreEditorFocus(context, editorState) ||
      _editorKeyboardIsVisible(context) ||
      editorState.selection != selection) {
    return;
  }

  final keyboardService = editorState.service.keyboardService;
  keyboardService?.closeKeyboard();
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted ||
      !_canRestoreEditorFocus(context, editorState) ||
      editorState.selection != selection) {
    return;
  }
  await editorState.updateSelectionWithReason(
    selection,
    reason: SelectionUpdateReason.uiEvent,
    extraInfo: extraInfo,
  );
}

Future<void> _waitForEditableSelectionTarget(
  EditorState editorState,
  Selection selection,
) async {
  // Three frames cover document notification, AppFlowy block construction and
  // final layout without creating an unbounded wait if the editor route has
  // already been removed. The caller separately checks BuildContext liveness.
  for (var attempt = 0; attempt < 3; attempt += 1) {
    if (editorState.isDisposed || !editorState.editable) return;
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node?.delta != null && node?.context != null) {
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
  }
}

bool _editorKeyboardIsVisible(BuildContext context) {
  final mediaQueryInset = MediaQuery.maybeOf(context)?.viewInsets.bottom ?? 0;
  final view = View.of(context);
  final physicalInset = view.viewInsets.bottom / view.devicePixelRatio;
  return mediaQueryInset > 0 || physicalInset > 0;
}

class _AddBlockSheet extends StatelessWidget {
  const _AddBlockSheet({required this.editorState, required this.bookmark});

  final EditorState editorState;
  final _EditorSelectionBookmark bookmark;

  // The add/more sheet is the exhaustive block picker, unlike the compact T
  // menu that progressively discloses deep headings. Expose every heading
  // level supported by the collaborative schema so H7-H9 can be inserted
  // directly without first walking through H3-H8.
  static const _maxHeadingLevel = 9;

  @override
  Widget build(BuildContext context) {
    final height = math.min(MediaQuery.sizeOf(context).height * 0.72, 640.0);
    return Container(
      key: const ValueKey('editor-add-block-sheet'),
      height: height,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SizedBox(
            height: 64,
            width: double.infinity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Text(
                  '添加',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                Positioned(
                  left: 8,
                  child: IconButton(
                    key: const ValueKey('editor-add-block-close'),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 28),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle('基础'),
                  const SizedBox(height: 14),
                  // H1-H9 belong to one ordered family, so a horizontal list
                  // preserves their sequence without wrapping H7-H9 onto a
                  // visually separate row. Explicit dimensions also keep the
                  // touch targets stable on narrow phones.
                  SizedBox(
                    height: 78,
                    child: ListView.separated(
                      key: const ValueKey('editor-add-heading-list'),
                      scrollDirection: Axis.horizontal,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
                      itemCount: _maxHeadingLevel,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final level = index + 1;
                        return SizedBox(
                          width: 52,
                          child: _HeadingShortcutTile(
                            level: level,
                            onTap: () => _applyAndClose(
                              context,
                              _BlockShortcut.heading(level),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount = constraints.maxWidth < 340 ? 4 : 5;
                      return GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.68,
                        children: [
                          _ActionShortcutTile(
                            key: const ValueKey(
                              'editor-shortcut-numbered-list',
                            ),
                            icon: Icons.format_list_numbered,
                            label: '有序列表',
                            onTap: () => _applyAndClose(
                              context,
                              const _BlockShortcut(NumberedListBlockKeys.type),
                            ),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey(
                              'editor-shortcut-bulleted-list',
                            ),
                            icon: Icons.format_list_bulleted,
                            label: '无序列表',
                            onTap: () => _applyAndClose(
                              context,
                              const _BlockShortcut(BulletedListBlockKeys.type),
                            ),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-todo-list'),
                            icon: Icons.check_box_outlined,
                            label: '任务列表',
                            onTap: () => _applyAndClose(
                              context,
                              const _BlockShortcut(TodoListBlockKeys.type),
                            ),
                          ),
                          const _ActionShortcutTile(
                            icon: Icons.data_object,
                            label: '代码块',
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-quote'),
                            icon: Icons.format_quote,
                            label: '引用',
                            onTap: () => _applyAndClose(
                              context,
                              const _BlockShortcut(QuoteBlockKeys.type),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  const _SectionTitle('常用'),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final crossAxisCount = constraints.maxWidth < 340 ? 4 : 5;
                      return GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 14,
                        crossAxisSpacing: 10,
                        childAspectRatio: 0.68,
                        children: [
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-image-block'),
                            icon: Icons.image_outlined,
                            label: '图片',
                            accent: const Color(0xFFF4B400),
                            tint: const Color(0xFFFFF8E1),
                            onTap: () => _requestUrlAndClose(
                              context,
                              ImageBlockKeys.type,
                            ),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-link-block'),
                            icon: Icons.link,
                            label: '链接',
                            accent: const Color(0xFF2563EB),
                            tint: const Color(0xFFDBEAFE),
                            onTap: () =>
                                _requestUrlAndClose(context, csesLinkBlockType),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-video-block'),
                            icon: Icons.movie_outlined,
                            label: '视频',
                            accent: const Color(0xFF7C3AED),
                            tint: const Color(0xFFEDE9FE),
                            onTap: () => _requestUrlAndClose(
                              context,
                              csesVideoBlockType,
                            ),
                          ),
                          for (final resource in const [
                            ('attachment', '附件', Icons.attach_file),
                            ('audio', '音频', Icons.audiotrack_outlined),
                            ('bookmark', '网页卡片', Icons.bookmark_border),
                            ('embed', '网页嵌入', Icons.language),
                            ('juejin-embed', '掘金', Icons.article_outlined),
                            (
                              'figma-embed',
                              'Figma',
                              Icons.design_services_outlined,
                            ),
                          ])
                            _ActionShortcutTile(
                              key: ValueKey(
                                'editor-shortcut-${resource.$1}-block',
                              ),
                              icon: resource.$3,
                              label: resource.$2,
                              accent: const Color(0xFF2563EB),
                              tint: const Color(0xFFEFF6FF),
                              onTap: () =>
                                  _requestUrlAndClose(context, resource.$1),
                            ),
                          const _ActionShortcutTile(
                            icon: Icons.table_chart_outlined,
                            label: '表格',
                            accent: Color(0xFF14B8A6),
                            tint: Color(0xFFCCFBF1),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-callout'),
                            icon: Icons.view_stream_outlined,
                            label: '高亮块',
                            accent: const Color(0xFFF97316),
                            tint: const Color(0xFFFFEDD5),
                            onTap: () async {
                              final capturedSelection = bookmark.resolve(
                                editorState,
                              );
                              if (capturedSelection == null) return;
                              final selection = await insertCollabCallout(
                                editorState,
                                capturedSelection,
                              );
                              if (context.mounted && selection != null) {
                                Navigator.pop<Selection>(context, selection);
                              }
                            },
                          ),
                          const _ActionShortcutTile(
                            icon: Icons.functions,
                            label: '公式',
                          ),
                          const _ActionShortcutTile(
                            icon: Icons.horizontal_rule,
                            label: '分隔线',
                            accent: Color(0xFF6366F1),
                            tint: Color(0xFFE0E7FF),
                          ),
                          const _ActionShortcutTile(
                            icon: Icons.grid_on_outlined,
                            label: '电子表格',
                            accent: Color(0xFF22C55E),
                            tint: Color(0xFFDCFCE7),
                          ),
                          const _ActionShortcutTile(
                            icon: Icons.dashboard_customize_outlined,
                            label: '多维表格',
                            accent: Color(0xFFA855F7),
                            tint: Color(0xFFF3E8FF),
                          ),
                          const _ActionShortcutTile(
                            icon: Icons.account_tree_outlined,
                            label: '思维导图',
                            accent: Color(0xFF06B6D4),
                            tint: Color(0xFFCFFAFE),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyAndClose(
    BuildContext context,
    _BlockShortcut shortcut,
  ) async {
    final capturedSelection = bookmark.resolve(editorState);
    if (capturedSelection == null) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
      return;
    }
    final applied = await applyBlockShortcut(
      editorState,
      capturedSelection,
      shortcut.blockType,
      headingLevel: shortcut.headingLevel,
    );
    if (context.mounted && applied) {
      // A non-empty source block inserts a new node and the transaction moves
      // selection to it. Converting an empty block can retain the captured
      // caret instead, so use that as a defensive fallback. Returning the
      // selection distinguishes a successful choice from manual cancellation.
      Navigator.pop<Selection>(
        context,
        editorState.selection ?? capturedSelection,
      );
    }
  }

  Future<void> _requestUrlAndClose(
    BuildContext context,
    String blockType,
  ) async {
    if (editorState.isDisposed || !editorState.editable) return;
    final source = await showEditorMediaSourceSheet(
      context,
      blockType: blockType,
      canEdit: () => !editorState.isDisposed && editorState.editable,
    );
    if (source == null || !context.mounted) return;
    final current = bookmark.resolve(editorState);
    final nextSelection = current == null
        ? null
        : await applyUrlBlockShortcut(
            editorState,
            current,
            blockType,
            source.url,
            mediaSource: source,
          );
    if (context.mounted && nextSelection != null) {
      Navigator.pop<Selection>(context, nextSelection);
    } else if (context.mounted) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
    }
  }
}

class _BlockShortcut {
  const _BlockShortcut(this.blockType) : headingLevel = null;

  const _BlockShortcut.heading(int level)
    : blockType = HeadingBlockKeys.type,
      headingLevel = level;

  final String blockType;
  final int? headingLevel;
}

/// Inserts a URL-backed block and returns the editable caret after it.
///
/// Link, image and video components are non-text blocks, so they cannot host
/// the IME caret themselves. A trailing empty paragraph is always retained or
/// created and selected. This is what makes choosing a block from “更多” return
/// immediately to editing with the keyboard open.
Future<Selection?> applyUrlBlockShortcut(
  EditorState editorState,
  Selection selection,
  String blockType,
  String url, {
  EditorMediaSource? mediaSource,
}) async {
  if (editorState.isDisposed ||
      !editorState.editable ||
      selection.start.path.isEmpty ||
      !_isUrlBackedBlockType(blockType) ||
      !_isSupportedBlockUrl(url) ||
      (isCollabResourceType(blockType) &&
          !isCollabResourceUrl(blockType, url))) {
    return null;
  }
  final targetPath = selection.start.path;
  final targetNode = editorState.getNodeAtPath(targetPath);
  if (targetNode == null) {
    return null;
  }

  final mediaNode = _urlBackedNode(
    blockType,
    url.trim(),
    mediaSource: mediaSource,
  );
  final sourceIsEmpty = targetNode.delta?.toPlainText().isEmpty == true;
  final insertPath = sourceIsEmpty ? targetPath : targetPath.next;
  final paragraphPath = insertPath.next;
  final paragraphNode = _emptyNode(ParagraphBlockKeys.type, null);
  final nextSelection = Selection.single(path: paragraphPath, startOffset: 0);

  final transaction = editorState.transaction;
  transaction.insertNodes(insertPath, [
    mediaNode,
    paragraphNode,
  ], deepCopy: false);
  if (sourceIsEmpty) {
    // Replace an unused text node instead of leaving a blank heading/list
    // around the media. The following paragraph becomes the sole editable
    // landing position and starts with the normal paragraph block type.
    // Insert before delete follows AppFlowy's own `formatNode` transaction
    // ordering. Its operation transformer can then identify and remove the
    // original node without shifting the newly inserted resource behind it.
    transaction.deleteNode(targetNode);
  }
  // Do not assign `transaction.afterSelection` here. This function is called
  // while a URL dialog and, in the “更多” flow, a bottom sheet still own focus.
  // Leaving it null closes the old editor input connection; the outer route
  // restores [nextSelection] only after every modal has been dismissed.
  await editorState.apply(transaction);
  return nextSelection;
}

Node _urlBackedNode(
  String blockType,
  String url, {
  EditorMediaSource? mediaSource,
}) {
  if (blockType == ImageBlockKeys.type) {
    return Node(
      type: ImageBlockKeys.type,
      attributes: {
        ImageBlockKeys.url: url,
        ImageBlockKeys.align: 'center',
        csesBlockIndentAttribute: 0,
      },
    );
  }
  return Node(
    type: blockType,
    attributes: {
      if (isCollabResourceType(blockType))
        ...CollabResource.fromValues({
          if (blockType == 'attachment')
            'name':
                mediaSource?.file?.name ??
                Uri.parse(url).pathSegments.lastOrNull ??
                '附件',
          if (blockType == 'audio')
            'sourceType': mediaSource?.file == null ? 'link' : 'local',
          if (mediaSource?.file != null &&
              {'audio', 'attachment'}.contains(blockType)) ...{
            'name': mediaSource!.file!.name,
            'size': mediaSource.file!.size,
            if (blockType == 'attachment') 'type': mediaSource.file!.mimeType,
          },
          if (blockType == 'bookmark') 'title': Uri.parse(url).host,
          if ({'embed', 'figma-embed', 'juejin-embed'}.contains(blockType)) ...{
            'wr': 100,
            'ar': 16 / 9,
          },
        }).nodeAttributes,
      csesEmbedUrlAttribute: url,
      blockComponentAlign: 'left',
      csesBlockIndentAttribute: 0,
    },
  );
}

bool _isUrlBackedBlockType(String blockType) =>
    isCollabResourceType(blockType) ||
    blockType == ImageBlockKeys.type ||
    blockType == csesLinkBlockType ||
    blockType == csesVideoBlockType;

bool _isSupportedBlockUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// Converts an empty selected block, or inserts a new block after non-empty text.
///
/// Exposed for widget/unit testing and for future toolbar surfaces.
Future<bool> applyBlockShortcut(
  EditorState editorState,
  Selection selection,
  String blockType, {
  int? headingLevel,
}) async {
  if (editorState.isDisposed ||
      !editorState.editable ||
      selection.start.path.isEmpty) {
    return false;
  }
  final targetPath = selection.start.path;
  final node = editorState.getNodeAtPath(targetPath);
  if (node == null || node.delta == null) {
    return false;
  }

  final text = node.delta?.toPlainText() ?? '';
  if (text.isEmpty) {
    final nodeSelection = Selection.single(path: targetPath, startOffset: 0);
    await editorState.formatNode(
      nodeSelection,
      (node) => _convertedNode(node, blockType, headingLevel),
    );
    return true;
  }

  final insertPath = targetPath.next;
  final transaction = editorState.transaction
    ..insertNode(
      insertPath,
      _emptyNode(blockType, headingLevel),
      deepCopy: false,
    )
    ..afterSelection = Selection.single(path: insertPath, startOffset: 0);
  await editorState.apply(transaction);
  return true;
}

Node _convertedNode(Node node, String blockType, int? headingLevel) {
  final collabBlockId = node.attributes['cses_collab_block_id'];
  final alignment = node.attributes[blockComponentAlign] as String? ?? 'left';
  final keepsIndent =
      blockType == BulletedListBlockKeys.type ||
      blockType == NumberedListBlockKeys.type ||
      blockType == TodoListBlockKeys.type;
  final attributes = <String, Object>{
    blockComponentDelta: (node.delta ?? Delta()).toJson(),
    blockComponentAlign: alignment,
    csesBlockIndentAttribute: keepsIndent
        ? (node.attributes[csesBlockIndentAttribute] as int? ?? 0).clamp(0, 6)
        : 0,
    if (blockType == HeadingBlockKeys.type)
      HeadingBlockKeys.level: (headingLevel ?? 1).clamp(1, 9),
    if (blockType == TodoListBlockKeys.type) TodoListBlockKeys.checked: false,
    if (blockType == 'code') blockComponentBackgroundColor: '0xfff3f4f6',
  };
  if (collabBlockId != null) {
    attributes['cses_collab_block_id'] = collabBlockId;
  }
  return Node(type: blockType, attributes: attributes);
}

Node _emptyNode(String blockType, int? headingLevel) {
  return Node(
    type: blockType,
    attributes: {
      blockComponentDelta: Delta().toJson(),
      blockComponentAlign: 'left',
      csesBlockIndentAttribute: 0,
      if (blockType == HeadingBlockKeys.type)
        HeadingBlockKeys.level: (headingLevel ?? 1).clamp(1, 9),
      if (blockType == TodoListBlockKeys.type) TodoListBlockKeys.checked: false,
      if (blockType == 'code') blockComponentBackgroundColor: '0xfff3f4f6',
    },
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
  }
}

class _HeadingShortcutTile extends StatelessWidget {
  const _HeadingShortcutTile({required this.level, required this.onTap});

  final int level;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('editor-shortcut-heading-$level'),
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Column(
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFF6F7F9),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Text(
                  'H$level',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text('标题 $level', style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}

class _ActionShortcutTile extends StatelessWidget {
  const _ActionShortcutTile({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.accent = const Color(0xFF374151),
    this.tint = const Color(0xFFF6F7F9),
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color accent;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap ?? () => _showUnsupportedMessage(context, label),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      icon,
                      color: enabled ? accent : accent.withValues(alpha: 0.78),
                      size: 28,
                    ),
                  ),
                ),
                if (!enabled)
                  const Positioned(
                    right: 5,
                    top: 4,
                    child: Icon(
                      Icons.schedule,
                      size: 12,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: enabled
                  ? const Color(0xFF111827)
                  : const Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }
}
