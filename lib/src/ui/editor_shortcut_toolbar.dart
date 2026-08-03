import 'dart:async';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_block_delete.dart';
import 'package:cses_mobile_collab_demo/src/ui/stable_mobile_toolbar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

class _EditorShortcutToolbarState extends State<EditorShortcutToolbar> {
  late _InlineStyleController _inlineStyleController;
  late final CollabUrlBackedBlockDeleteInterceptor _blockDeleteInterceptor;
  AppFlowyKeyboardService? _interceptedKeyboardService;
  int _emptyParagraphKeyboardRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    registerCsesRichTextAttributes();
    _inlineStyleController = _InlineStyleController(widget.editorState);
    _blockDeleteInterceptor = CollabUrlBackedBlockDeleteInterceptor();
    widget.editorState.selectionNotifier.addListener(
      _onSelectionMayNeedEmptyParagraphKeyboard,
    );
    _registerBlockDeleteInterceptorAfterLayout();
  }

  @override
  void didUpdateWidget(covariant EditorShortcutToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editorState != widget.editorState) {
      _unregisterBlockDeleteInterceptor();
      oldWidget.editorState.selectionNotifier.removeListener(
        _onSelectionMayNeedEmptyParagraphKeyboard,
      );
      _inlineStyleController.dispose();
      _inlineStyleController = _InlineStyleController(widget.editorState);
      widget.editorState.selectionNotifier.addListener(
        _onSelectionMayNeedEmptyParagraphKeyboard,
      );
      _registerBlockDeleteInterceptorAfterLayout();
    }
  }

  @override
  void dispose() {
    _unregisterBlockDeleteInterceptor();
    widget.editorState.selectionNotifier.removeListener(
      _onSelectionMayNeedEmptyParagraphKeyboard,
    );
    _inlineStyleController.dispose();
    super.dispose();
  }

  void _registerBlockDeleteInterceptorAfterLayout() {
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
      keyboardService.registerInterceptor(_blockDeleteInterceptor);
      _interceptedKeyboardService = keyboardService;
    });
  }

  void _unregisterBlockDeleteInterceptor() {
    _interceptedKeyboardService?.unregisterInterceptor(_blockDeleteInterceptor);
    _interceptedKeyboardService = null;
  }

  void _onSelectionMayNeedEmptyParagraphKeyboard() {
    final requestGeneration = ++_emptyParagraphKeyboardRequestGeneration;
    final selection = widget.editorState.selection;
    if (defaultTargetPlatform != TargetPlatform.android ||
        selection == null ||
        !selection.isCollapsed ||
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

class _BlockLayoutMenu extends StatefulWidget {
  const _BlockLayoutMenu({required this.editorState});

  final EditorState editorState;

  @override
  createState() => _BlockLayoutMenuState();
}

class _BlockLayoutMenuState extends State<_BlockLayoutMenu> {
  static const _indentableTypes = {
    BulletedListBlockKeys.type,
    NumberedListBlockKeys.type,
    TodoListBlockKeys.type,
  };

  @override
  Widget build(BuildContext context) {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    final canIndent =
        nodes.isNotEmpty &&
        nodes.every((node) => _indentableTypes.contains(node.type));
    final canOutdent = canIndent && nodes.any((node) => _indentOf(node) > 0);
    final canIncreaseIndent =
        canIndent && nodes.every((node) => _indentOf(node) < 6);

    return ListView(
      key: const ValueKey('editor-block-layout-menu'),
      scrollDirection: Axis.horizontal,
      children: [
        _PopupIconButton(
          key: const ValueKey('editor-block-outdent'),
          tooltip: '取消缩进',
          enabled: canOutdent,
          selected: false,
          icon: const Icon(Icons.format_indent_decrease, size: 28),
          onPressed: () => _changeIndent(selection, -1),
        ),
        const SizedBox(width: 5),
        _PopupIconButton(
          key: const ValueKey('editor-block-indent'),
          tooltip: '增加缩进',
          enabled: canIncreaseIndent,
          selected: false,
          icon: const Icon(Icons.format_indent_increase, size: 28),
          onPressed: () => _changeIndent(selection, 1),
        ),
        const SizedBox(width: 10),
        for (final option in const [
          ('left', '左对齐', Icons.format_align_left),
          ('center', '居中', Icons.format_align_center),
          ('right', '右对齐', Icons.format_align_right),
        ]) ...[
          _PopupIconButton(
            key: ValueKey('editor-block-align-${option.$1}'),
            tooltip: option.$2,
            selected:
                nodes.isNotEmpty &&
                nodes.every((node) => _alignmentOf(node) == option.$1),
            icon: Icon(option.$3, size: 28),
            onPressed: () => _setAlignment(selection, option.$1),
          ),
          const SizedBox(width: 5),
        ],
      ],
    );
  }

  int _indentOf(Node node) {
    final value = node.attributes[csesBlockIndentAttribute];
    return value is int ? value.clamp(0, 6) : 0;
  }

  String _alignmentOf(Node node) {
    final value = node.attributes[blockComponentAlign];
    return value == 'center' || value == 'right' ? value as String : 'left';
  }

  Future<void> _changeIndent(Selection selection, int delta) async {
    await widget.editorState.updateNode(
      selection,
      (node) => node.copyWith(
        attributes: {
          ...node.attributes,
          csesBlockIndentAttribute: (_indentOf(node) + delta).clamp(0, 6),
        },
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _setAlignment(Selection selection, String alignment) async {
    await widget.editorState.updateNode(
      selection,
      (node) => node.copyWith(
        attributes: {...node.attributes, blockComponentAlign: alignment},
      ),
    );
    if (mounted) {
      setState(() {});
    }
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
      cacheExtent: 1000,
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
          onPressed: () => _apply(selection, style),
        );
      },
    );
  }

  Future<void> _apply(Selection selection, _BlockStyleAction style) async {
    final selectedNode = widget.editorState.getNodeAtPath(selection.start.path);
    if (selectedNode?.type == csesDocumentTitleBlockType) {
      // The title uses a text Delta for native IME behavior, but its block type
      // is a fixed document invariant and must not become a heading/list/body.
      return;
    }
    await widget.editorState.formatNode(
      selection,
      (node) => _convertedNode(node, style.blockType, style.headingLevel),
    );
    if (!mounted) {
      return;
    }
    final level = style.headingLevel;
    setState(() {
      if (level != null && level >= 3 && level < 9) {
        _maxHeadingLevel = math.max(_maxHeadingLevel, level + 1);
      } else if (level == null || level < 3) {
        // Paragraph, list, Todo, code and quote actions have no heading level.
        // They start a fresh heading-selection flow, just like H1 and H2, so
        // the menu returns to H1-H3 and hides every progressively revealed row.
        _maxHeadingLevel = 3;
      }
    });
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
      cacheExtent: 1000,
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

Future<void> showEditorAddBlockSheet(
  BuildContext context,
  EditorState editorState,
) async {
  final selection = editorState.selection;
  if (selection == null) {
    _showToolbarMessage(context, '请先把光标放入正文');
    return;
  }

  final previousExtraInfo = editorState.selectionExtraInfo == null
      ? null
      : Map<Object?, Object?>.from(editorState.selectionExtraInfo!);
  editorState.selectionExtraInfo = {
    ...?previousExtraInfo,
    selectionExtraInfoDisableMobileToolbarKey: true,
  };
  // PropertyValueNotifier intentionally notifies even for the same selection,
  // forcing MobileToolbarV2 to rebuild with the disabled flag immediately.
  editorState.selection = selection;

  Selection? appliedSelection;
  try {
    FocusManager.instance.primaryFocus?.unfocus();
    appliedSelection = await showModalBottomSheet<Selection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _AddBlockSheet(
        editorState: editorState,
        capturedSelection: selection,
      ),
    );
  } finally {
    if (appliedSelection == null) {
      // Closing the sheet without choosing a block is a cancellation. Restore
      // the previous toolbar metadata and leave the editor unfocused so a
      // cancel action never opens the keyboard unexpectedly.
      editorState.selectionExtraInfo = previousExtraInfo;
      editorState.selection = null;
    } else {
      if (!context.mounted) {
        // The owning editor route disappeared while its child modal was
        // closing. Preserve the logical selection metadata, but never request
        // focus through a disposed BuildContext.
        editorState.selectionExtraInfo = previousExtraInfo;
        editorState.selection = appliedSelection;
      } else {
        await _restoreEditorCaretAndKeyboard(
          context,
          editorState,
          appliedSelection,
          extraInfo: previousExtraInfo,
        );
      }
    }
  }
}

/// Prompts for a URL and inserts a link, image or video from the compact
/// keyboard toolbar.
///
/// The dialog temporarily hides the IME. After insertion the returned caret is
/// restored to the trailing paragraph and explicitly handed back to AppFlowy's
/// keyboard service, matching the behavior of selections made in the add
/// sheet.
Future<void> showEditorUrlBlockDialog(
  BuildContext context,
  EditorState editorState,
  String blockType,
) async {
  final selection = editorState.selection;
  if (selection == null) {
    _showToolbarMessage(context, '请先把光标放入正文');
    return;
  }

  FocusManager.instance.primaryFocus?.unfocus();
  final url = await showDialog<String>(
    context: context,
    builder: (context) => _UrlBlockDialog(blockType: blockType),
  );
  if (url == null || !context.mounted) {
    return;
  }

  final nextSelection = await applyUrlBlockShortcut(
    editorState,
    selection,
    blockType,
    url,
  );
  if (!context.mounted) {
    return;
  }
  if (nextSelection == null) {
    _showToolbarMessage(context, '插入失败，请重新选择正文位置');
    return;
  }
  await _restoreEditorCaretAndKeyboard(context, editorState, nextSelection);
}

/// Adds, replaces or removes the fixed document cover URL.
///
/// The cover is a structural collaborative block, so changing its URL uses a
/// normal AppFlowy transaction and is published through the same adapter path
/// as body edits. No caret is restored because the cover itself is non-text.
Future<void> showEditorDocumentCoverDialog(
  BuildContext context,
  EditorState editorState,
  Node coverNode,
) async {
  final currentUrl =
      coverNode.attributes[csesEmbedUrlAttribute] as String? ?? '';
  FocusManager.instance.primaryFocus?.unfocus();
  final nextUrl = await showDialog<String>(
    context: context,
    builder: (context) => _UrlBlockDialog(
      blockType: csesDocumentCoverBlockType,
      initialValue: currentUrl,
      allowRemove: currentUrl.isNotEmpty,
    ),
  );
  if (nextUrl == null || !context.mounted) {
    return;
  }
  final latestNode = editorState.document.nodeAtPath(coverNode.path);
  if (latestNode == null || latestNode.type != csesDocumentCoverBlockType) {
    _showToolbarMessage(context, '封面已被远端修改，请重试');
    return;
  }
  final transaction = editorState.transaction
    ..updateNode(latestNode, {csesEmbedUrlAttribute: nextUrl});
  await editorState.apply(transaction);
}

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
  if (!context.mounted) {
    return;
  }

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
      _editorKeyboardIsVisible(context) ||
      editorState.selection != selection) {
    return;
  }

  final keyboardService = editorState.service.keyboardService;
  keyboardService?.closeKeyboard();
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted || editorState.selection != selection) {
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
  const _AddBlockSheet({
    required this.editorState,
    required this.capturedSelection,
  });

  final EditorState editorState;
  final Selection capturedSelection;

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
                      cacheExtent: 1000,
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
                          const _ActionShortcutTile(
                            icon: Icons.attach_file,
                            label: '文件',
                            accent: Color(0xFF0EA5E9),
                            tint: Color(0xFFE0F2FE),
                          ),
                          const _ActionShortcutTile(
                            icon: Icons.table_chart_outlined,
                            label: '表格',
                            accent: Color(0xFF14B8A6),
                            tint: Color(0xFFCCFBF1),
                          ),
                          const _ActionShortcutTile(
                            icon: Icons.view_stream_outlined,
                            label: '高亮块',
                            accent: Color(0xFFF97316),
                            tint: Color(0xFFFFEDD5),
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
    final url = await showDialog<String>(
      context: context,
      builder: (context) => _UrlBlockDialog(blockType: blockType),
    );
    if (url == null) {
      // Cancelling only the nested URL dialog keeps the add sheet open so the
      // user can choose a different block without losing the captured caret.
      return;
    }

    final nextSelection = await applyUrlBlockShortcut(
      editorState,
      capturedSelection,
      blockType,
      url,
    );
    if (context.mounted && nextSelection != null) {
      Navigator.pop<Selection>(context, nextSelection);
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

class _UrlBlockDialog extends StatefulWidget {
  const _UrlBlockDialog({
    required this.blockType,
    this.initialValue = '',
    this.allowRemove = false,
  });

  final String blockType;
  final String initialValue;
  final bool allowRemove;

  @override
  State<_UrlBlockDialog> createState() => _UrlBlockDialogState();
}

class _UrlBlockDialogState extends State<_UrlBlockDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  String get _label => switch (widget.blockType) {
    ImageBlockKeys.type => '图片链接',
    csesVideoBlockType => '视频链接',
    csesDocumentCoverBlockType => '封面图片链接',
    _ => '网页链接',
  };

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  void _submit() {
    final value = _controller.text.trim();
    if (!_isSupportedBlockUrl(value)) {
      setState(() => _errorText = '请输入完整的 http:// 或 https:// 链接');
      return;
    }
    Navigator.pop<String>(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: ValueKey('editor-${widget.blockType}-url-dialog'),
      title: Text('插入$_label'),
      content: TextField(
        key: const ValueKey('editor-url-block-input'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: _label,
          hintText: 'https://example.com/resource',
          errorText: _errorText,
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) {
          // Clear a stale validation message as soon as the user edits the
          // value; validation runs again on submission against trimmed input.
          if (_errorText != null) {
            setState(() => _errorText = null);
          }
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        if (widget.allowRemove)
          TextButton(
            key: const ValueKey('editor-cover-url-remove'),
            onPressed: () => Navigator.pop<String>(context, ''),
            child: const Text('移除封面'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('editor-url-block-submit'),
          onPressed: _submit,
          child: const Text('插入'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
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
  String url,
) async {
  if (selection.start.path.isEmpty ||
      !_isUrlBackedBlockType(blockType) ||
      !_isSupportedBlockUrl(url)) {
    return null;
  }
  final targetPath = [selection.start.path.first];
  final targetNode = editorState.getNodeAtPath(targetPath);
  if (targetNode == null) {
    return null;
  }

  final mediaNode = _urlBackedNode(blockType, url.trim());
  final sourceIsEmpty = targetNode.delta?.toPlainText().isEmpty == true;
  final insertPath = sourceIsEmpty ? targetPath : [targetPath.first + 1];
  final paragraphPath = [insertPath.first + 1];
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

Node _urlBackedNode(String blockType, String url) {
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
      csesEmbedUrlAttribute: url,
      blockComponentAlign: 'left',
      csesBlockIndentAttribute: 0,
    },
  );
}

bool _isUrlBackedBlockType(String blockType) =>
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
  if (selection.start.path.isEmpty) {
    return false;
  }
  final targetPath = [selection.start.path.first];
  final node = editorState.getNodeAtPath(targetPath);
  if (node == null) {
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

  final insertPath = [targetPath.first + 1];
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
