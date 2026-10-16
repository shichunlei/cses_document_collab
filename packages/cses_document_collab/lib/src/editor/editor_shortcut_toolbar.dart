import 'dart:async';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_color_picker.dart';
import 'package:cses_document_collab/src/editor/collab_formula_sheet.dart';
import 'package:cses_document_collab/src/editor/collab_host_meeting_ui.dart';
import 'package:cses_document_collab/src/editor/collab_host_mention_ui.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_typing.dart';
import 'package:cses_document_collab/src/editor/editor_media_source_sheet.dart';
import 'package:cses_document_collab/src/editor/stable_mobile_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:cses_document_collab/src/model/collab_text_range.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

/// 移动键盘工具栏，借用正文编辑器并隔离添加面板的输入与选区。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
/// final state = EditorState.blank();
/// final toolbar = EditorShortcutToolbar(editorState: state, child: AppFlowyEditor(editorState: state));
/// // 从树中移除toolbar后由创建方state.dispose()。
/// ```
///
/// Only commands represented by the current collaborative schema are active.
/// Unsupported actions stay visible so the interaction model can be evaluated
/// without silently creating local-only nodes that Rust/Yrs cannot preserve.
class EditorShortcutToolbar extends StatefulWidget {
  /// [key] 控制身份与状态复用，[editorState] 为借用编辑器，[child] 为必填正文。
  const EditorShortcutToolbar({super.key, required this.editorState, required this.child});

  /// 必填借用编辑器；本组件管理工具栏状态，不释放它。
  final EditorState editorState;

  /// 必填正文组件，工具栏随键盘在其下方显示。
  final Widget child;

  /// 创建并持有工具栏控制器与键盘拦截器。
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
    widget.editorState.selectionNotifier.addListener(_onSelectionMayNeedEmptyParagraphKeyboard);
    _registerBackspaceInterceptorAfterLayout();
  }

  /// [oldWidget] 提供旧编辑器；编辑器更换时先注销旧服务/选区监听并释放旧样式控制器，
  /// 再绑定当前编辑器。键盘服务和 EditorState 均由外部持有，不在此关闭。
  @override
  void didUpdateWidget(covariant EditorShortcutToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editorState != widget.editorState) {
      _unregisterBackspaceInterceptor();
      oldWidget.editorState.selectionNotifier.removeListener(_onSelectionMayNeedEmptyParagraphKeyboard);
      _inlineStyleController.dispose();
      _inlineStyleController = _InlineStyleController(widget.editorState);
      widget.editorState.selectionNotifier.addListener(_onSelectionMayNeedEmptyParagraphKeyboard);
      _registerBackspaceInterceptorAfterLayout();
    }
  }

  /// 注销借用服务上的退格拦截器及选区监听，释放所属样式控制器；外部编辑器保持有效。
  @override
  void dispose() {
    _unregisterBackspaceInterceptor();
    widget.editorState.selectionNotifier.removeListener(_onSelectionMayNeedEmptyParagraphKeyboard);
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
        widget.editorState.selectionExtraInfo?[selectionExtraInfoDoNotAttachTextService] == true ||
        widget.editorState.selectionUpdateReason != SelectionUpdateReason.uiEvent) {
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
    unawaited(_showKeyboardForEmptyParagraphIfStillNeeded(selection, requestGeneration));
  }

  Future<void> _showKeyboardForEmptyParagraphIfStillNeeded(Selection selection, int requestGeneration) async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted ||
        requestGeneration != _emptyParagraphKeyboardRequestGeneration ||
        widget.editorState.selection != selection ||
        widget.editorState.selectionExtraInfo?[selectionExtraInfoDoNotAttachTextService] == true ||
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

  /// 在借用 [context] 中按平台提供移动工具栏，包括人员提及入口。
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS) {
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
        _mentionToolbarItem,
      ],
      child: widget.child,
    );
  }
}

/// 格式菜单的轻量订阅，输入继承由编辑器适配器统一维护；不拥有编辑器。
class _InlineStyleController extends ChangeNotifier {
  /// 订阅借用的 [editorState] 输入状态，创建者负责 dispose。
  _InlineStyleController(this.editorState) {
    _typing = CollabParagraphTyping.isAttached(editorState) ? null : CollabParagraphTyping(editorState);
    editorState.toggledStyleNotifier.addListener(notifyListeners);
    editorState.selectionNotifier.addListener(notifyListeners);
  }

  /// 仅独立编辑器场景由工具栏持有，适配器场景不重复创建。
  CollabParagraphTyping? _typing;

  /// 宿主持有的文档编辑器。
  final EditorState editorState;

  /// 读取 [attribute] 的当前输入格式；null 表示未设置。
  dynamic value(String attribute) => editorState.toggledStyle[attribute];

  /// 切换 [attribute]，可同时取消 [mutuallyExclusiveWith]；空段落格式持久化并可撤销。
  Future<void> toggle(String attribute, {String? mutuallyExclusiveWith}) => setCollabTypingAttributes(editorState, {
    attribute: value(attribute) == true ? null : true,
    ?mutuallyExclusiveWith: null,
  });

  /// 设置 [attribute] 为 [value]，null 取消；等待空段落格式事务完成，失败向菜单边界传播。
  Future<void> setValue(String attribute, dynamic value) => setCollabTypingAttributes(editorState, {attribute: value});

  /// 范围格式由选区直接计算，不需要修改输入状态。
  void clearAll() {}

  /// 仅注销自身监听；借用编辑器由宿主释放。
  @override
  void dispose() {
    _typing?.dispose();
    editorState.toggledStyleNotifier.removeListener(notifyListeners);
    editorState.selectionNotifier.removeListener(notifyListeners);
    super.dispose();
  }
}

final _addBlockToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '添加块',
    child: KeyedSubtree(key: ValueKey('editor-shortcut-add'), child: Icon(Icons.add_circle_outline, size: 27)),
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
    child: KeyedSubtree(key: ValueKey('editor-shortcut-image'), child: Icon(Icons.image_outlined)),
  ),
  actionHandler: (context, editorState) {
    unawaited(showEditorUrlBlockDialog(context, editorState, ImageBlockKeys.type));
  },
);

/// 人员工具栏入口；异步错误由完整弹窗流程报告，正文位置独立保存。
final _mentionToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '@用户',
    child: KeyedSubtree(key: ValueKey('editor-shortcut-mention'), child: Icon(Icons.alternate_email)),
  ),
  actionHandler: (context, state) {
    unawaited(showEditorUserMentionSheet(context, state));
  },
);

/// 在借用 [context]/[editorState] 中调用宿主选择并插入用户；未注入选人端口不打开界面。
/// [keyword] 为初始搜索词，默认空字符串；[replaceTrigger] 为true时替换光标前的@。
/// 保存稳定块身份和原正文，远端重排可重定位，正文变化/删除/权限撤销拒绝提交。
/// 关闭动画完成后恢复原选区或插入后的光标；取消不写正文，失败报告并保留内容。
Future<void> showEditorUserMentionSheet(
  BuildContext context,
  EditorState editorState, {
  String keyword = '',
  bool replaceTrigger = false,
}) async {
  if (editorState.isDisposed || !editorState.editable) return;
  final services = CollabRuntime.services;
  if (services.pickMentionUser == null) {
    _showToolbarMessage(context, '宿主未提供人员选择器');
    return;
  }
  final selection = editorState.selection;
  if (selection == null || !selection.isSingle) {
    _showToolbarMessage(context, '请选择同一段正文中的位置');
    return;
  }
  final node = editorState.getNodeAtPath(selection.start.path);
  if (node?.delta == null || node!.type == 'code') {
    _showToolbarMessage(context, '此位置不支持用户提及');
    return;
  }
  final id = _mediaTargetId(node);
  final original = node.delta!.toPlainText();
  final range = selection.normalized;
  final originalRange = node.delta!.slice(range.start.offset, range.end.offset);
  final session = _EditorModalSession(editorState);
  Selection? landing;
  try {
    final user = await pickHostMentionUser(context, editorState, keyword: keyword);
    if (user == null || !context.mounted) return;
    final current = session.bookmark?.resolve(editorState);
    final target = findCollabInlineTextNode(editorState, id);
    if (current == null ||
        target?.delta?.toPlainText() != original ||
        target!.delta!.slice(current.normalized.start.offset, current.normalized.end.offset) != originalRange) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
      return;
    }
    var insertion = current;
    if (replaceTrigger) {
      final offset = current.start.offset;
      if (!current.isCollapsed || offset <= 0 || target.delta!.toPlainText()[offset - 1] != '@') {
        return;
      }
      insertion = Selection.single(path: current.start.path, startOffset: offset - 1, endOffset: offset);
    }
    landing = await insertCollabUserMention(editorState, insertion, user);
    if (context.mounted && landing == null) {
      _showToolbarMessage(context, '无法插入此用户提及');
    }
  } catch (error, stack) {
    services.report('插入用户提及失败', error, stack, 'DocCollab');
    if (context.mounted && identical(CollabRuntime.services, services)) {
      _showToolbarMessage(context, '插入失败，请重试');
    }
  } finally {
    await session.finish(context.mounted && identical(CollabRuntime.services, services) ? context : null, landing);
  }
}

MobileToolbarItem _textDecorationToolbarItem(_InlineStyleController inlineStyleController) =>
    MobileToolbarItem.withMenu(
      itemIconBuilder: (context, editorState, isSelected) => KeyedSubtree(
        key: const ValueKey('editor-shortcut-inline-style'),
        child: textDecorationMobileToolbarItemV2.itemIconBuilder!(context, editorState, isSelected)!,
      ),
      itemMenuBuilder: (_, editorState, service) =>
          _InlineStyleMenu(editorState: editorState, inlineStyleController: inlineStyleController),
    );

/// 为借用 [context]/[editorState] 中的文字范围打开格式面板，复用键盘工具栏的 T、Aa 和布局控件。
/// 允许连续格式修改；正文变化、删除或权限撤销后禁用面板，取消不修改正文。
/// 面板拥有局部样式控制器，退场后恢复稳定选区及正文输入，不释放编辑器。
Future<void> showEditorSelectionFormats(BuildContext context, EditorState editorState) async {
  final range = CollabTextRange.capture(editorState);
  if (!editorState.editable || range == null || !range.hasText) return;
  try {
    await runEditorHeaderAction<void>(context, editorState, () async {
      editorState.selection = range.resolve(editorState);
      ModalRoute<void>? route;
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        showDragHandle: true,
        requestFocus: false,
        builder: (sheetContext) {
          route = ModalRoute.of<void>(sheetContext);
          return _SelectionFormatSheet(editorState: editorState, range: range);
        },
      );
      await route?.completed;
    }, selectionAfterAction: () => editorState.selection);
  } catch (error, stack) {
    CollabDiagnostics.report('划词格式修改失败', error: error, stackTrace: stack, tag: 'DocCollab');
    if (context.mounted) _showToolbarMessage(context, '格式修改失败，请重试');
  }
}

/// 借用当前范围显示现有格式控件，持有独立的样式状态。
class _SelectionFormatSheet extends StatefulWidget {
  /// [editorState] 由宿主持有，[range] 保存打开时的稳定身份和正文快照。
  const _SelectionFormatSheet({required this.editorState, required this.range});

  /// 借用的正文编辑器，面板退出时不关闭。
  final EditorState editorState;

  /// 打开时的稳定范围，格式变化可持续应用，正文变化后禁止继续操作。
  final CollabTextRange range;

  /// 创建面板拥有的样式控制器状态。
  @override
  createState() => _SelectionFormatSheetState();
}

/// 复用格式、类型与布局命令；每次触摸前按稳定身份重定位，避免远端重排改到其他段落。
class _SelectionFormatSheetState extends State<_SelectionFormatSheet> {
  late final _InlineStyleController _styles;

  /// 稳定范围仅跟随本面板的类型/缩进命令；null表示目标已不支持文字划词。
  CollabTextRange? _range;

  /// 创建面板使用的样式状态，不接管编辑器资源。
  @override
  void initState() {
    super.initState();
    _styles = _InlineStyleController(widget.editorState);
    _range = widget.range;
  }

  /// 接收本面板命令同步写入后捕获的 [range]，保留之后远端变化的失效检查。
  /// 不从异步完成时的实时选区重建，避免把等待期间的远端正文误认成本地转换结果。
  void _acceptLocalRange(CollabTextRange? range) {
    if (mounted) setState(() => _range = range);
  }

  /// 释放本面板的选区监听，编辑器由调用方释放。
  @override
  void dispose() {
    _styles.dispose();
    super.dispose();
  }

  /// 在借用 [context] 中随事务和权限更新面板；失效时只保留关闭操作。
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.editorState.editableNotifier, widget.editorState.selectionNotifier]),
    builder: (context, _) => StreamBuilder<EditorTransactionValue>(
      stream: widget.editorState.transactionStream,
      builder: (context, _) {
        final selection = _range?.resolve(widget.editorState, checkFormatting: false);
        final enabled = widget.editorState.editable && selection != null;
        return SafeArea(
          child: MobileToolbarTheme(
            child: Padding(
              key: const ValueKey('editor-selection-format-sheet'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('文字格式', style: TextStyle(fontSize: 18))),
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
                    ],
                  ),
                  if (!enabled) const Text('选区或编辑权限已变化，请关闭后重新选择'),
                  IgnorePointer(
                    ignoring: !enabled,
                    child: Listener(
                      onPointerDown: (_) {
                        final current = _range?.resolve(widget.editorState, checkFormatting: false);
                        widget.editorState.selection = widget.editorState.editable ? current : null;
                        if (current == null) {
                          setState(() {});
                        }
                      },
                      child: Opacity(
                        opacity: enabled ? 1 : .35,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: 60,
                              child: _BlockStyleMenu(
                                editorState: widget.editorState,
                                onRangeChanged: _acceptLocalRange,
                              ),
                            ),
                            SizedBox(
                              height: 60,
                              child: _InlineStyleMenu(editorState: widget.editorState, inlineStyleController: _styles),
                            ),
                            SizedBox(
                              height: 60,
                              child: _BlockLayoutMenu(
                                editorState: widget.editorState,
                                onRangeChanged: _acceptLocalRange,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

final _blockStyleToolbarItem = MobileToolbarItem.withMenu(
  itemIconBuilder: (context, editorState, service) => const KeyedSubtree(
    key: ValueKey('editor-shortcut-block-style'),
    child: Tooltip(
      message: '块类型',
      child: Text('T', style: TextStyle(fontSize: 29, height: 1, fontWeight: FontWeight.w500)),
    ),
  ),
  itemMenuBuilder: (_, editorState, service) => _BlockStyleMenu(editorState: editorState),
);

/// 块布局菜单，借用 [EditorState] 显示对齐、普通文本段及三种列表缩进，不拥有编辑器资源。
class _BlockLayoutMenu extends StatefulWidget {
  /// [editorState] 为借用编辑器；[onRangeChanged] 可接收本地缩进命令的结果快照，默认不通知。
  const _BlockLayoutMenu({required this.editorState, this.onRangeChanged});

  /// 借用的编辑器，提供选区与事务；由宿主释放，菜单不关闭键盘或编辑器。
  final EditorState editorState;

  /// 本地缩进完成时通知格式面板；null结果表示目标已不支持划词，不跟随远端类型变化。
  final ValueChanged<CollabTextRange?>? onRangeChanged;

  /// 创建仅管理菜单展示的状态；列表写入由共用事务负责。
  @override
  createState() => _BlockLayoutMenuState();
}

/// 根据当前选区展示可用操作；点击时重新校验，事务完成后在仍挂载且编辑器未更换时刷新。
class _BlockLayoutMenuState extends State<_BlockLayoutMenu> {
  String? _colorAttribute;

  /// 为借用的 [nodes] 汇总当前块颜色，背景与边框使用同一桌面浅色色板。
  Widget _buildBlockColors(List<Node> nodes) {
    final attribute = _colorAttribute!;
    final isBorder = attribute == csesBlockBorderColorAttribute;
    final targets = nodes.where((node) => node.delta != null && (!isBorder || node.type == QuoteBlockKeys.type));
    return CollabColorPicker(
      keyPrefix: isBorder ? 'editor-block-border-color' : 'editor-block-background-color',
      horizontal: true,
      selection: CollabColorSelection.fromValues(targets.map((node) => node.attributes[attribute] as String?)),
      resetLabel: isBorder ? '默认线条颜色' : '清除块背景色',
      onBack: () => setState(() => _colorAttribute = null),
      onSelected: _setBlockColor,
    );
  }

  /// 将用户选择的 CSS [value] 写入实时选区；null 恢复默认，其他既有颜色不变。
  /// 正文块背景另投影为 AppFlowy ARGB，保存失败交给共用选择器报告。
  Future<void> _setBlockColor(String? value) async {
    final state = widget.editorState;
    final selection = state.selection;
    final attribute = _colorAttribute;
    if (state.isDisposed || !state.editable || selection == null || attribute == null) {
      return;
    }
    final transaction = state.transaction;
    for (final node in state.getNodesInSelection(selection)) {
      if (node.delta == null || (attribute == csesBlockBorderColorAttribute && node.type != QuoteBlockKeys.type)) {
        continue;
      }
      if (sameCollabColor(node.attributes[attribute] as String?, value)) {
        continue;
      }
      transaction.updateNode(node, {
        attribute: value,
        if (attribute == csesBlockBackgroundColorAttribute) blockComponentBackgroundColor: collabColorToEditor(value),
      });
    }
    if (transaction.operations.isEmpty) return;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
    if (mounted && identical(widget.editorState, state)) setState(() {});
  }

  /// 使用 [context] 渲染布局按钮；文本段遵守8级及兄弟深度约束，0级列表仍可退为段落。
  @override
  Widget build(BuildContext context) {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    if (_colorAttribute != null) return _buildBlockColors(nodes);
    final canOutdent = canChangeCollabBlockIndent(widget.editorState, -1);
    final canIncreaseIndent = canChangeCollabBlockIndent(widget.editorState, 1);

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
            enabled: !const {'justify', 'distributed'}.contains(option.$1) || nodes.every((n) => n.delta != null),
            selected: nodes.isNotEmpty && nodes.every((node) => _alignmentOf(node) == option.$1),
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
          onPressed: () => setState(() => _colorAttribute = csesBlockBackgroundColorAttribute),
        ),
        if (nodes.any((n) => n.type == QuoteBlockKeys.type))
          _PopupIconButton(
            key: const ValueKey('editor-block-border-color'),
            tooltip: '左侧线条颜色',
            selected: false,
            icon: const Icon(Icons.border_left, size: 28),
            onPressed: () => setState(() => _colorAttribute = csesBlockBorderColorAttribute),
          ),
        for (final option in const [
          (null, '下一段：默认', Icons.settings_backup_restore),
          ('same', '下一段：延续样式', Icons.subdirectory_arrow_right),
          ('body', '下一段：正文', Icons.notes),
        ])
          _PopupIconButton(
            key: ValueKey('editor-next-paragraph-${option.$1 ?? 'default'}'),
            tooltip: option.$2,
            enabled: nodes.any(supportsCollabParagraph),
            selected:
                nodes.isNotEmpty &&
                nodes.every(
                  (node) =>
                      supportsCollabParagraph(node) &&
                      readCollabParagraph(node).values['nextParagraphStyle'] == option.$1,
                ),
            icon: Icon(option.$3, size: 28),
            onPressed: () => unawaited(_setNextParagraphStyle(option.$1)),
          ),
      ],
    );
  }

  /// 设置实时选区的下一段 [style]，null 恢复默认；失败由共用诊断边界报告。
  Future<void> _setNextParagraphStyle(String? style) async {
    final state = widget.editorState;
    try {
      await setCollabNextParagraphStyle(state, style);
      if (mounted && identical(widget.editorState, state)) setState(() {});
    } catch (error, stackTrace) {
      CollabDiagnostics.report('设置下一段样式失败', error: error, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('设置失败，请重试')));
      }
    }
  }

  /// 读取借用 [node] 的展示对齐方式；未知/缺失值回退 left，无副作用。
  String _alignmentOf(Node node) {
    final value = node.attributes[blockComponentAlign];
    return const {'left', 'center', 'right', 'justify', 'distributed'}.contains(value) ? value as String : 'left';
  }

  /// 将 [delta]（-1/+1）应用到点击时的当前选区；复用整组选区一个事务及原光标恢复。
  /// 不缓存 build 时选区，失效/只读或上限条件不执行。等待事务完成后检查 mounted 和编辑器
  /// 身份及存活状态再刷新；非预期异常保留错误/堆栈上报 Log.e，并交 FlutterError，不重复用户提示。
  /// 列表零级退为段落时，将同步结果快照交还格式面板，以接续其后操作。
  Future<void> _changeIndent(int delta) async {
    final state = widget.editorState;
    try {
      final completion = changeCollabBlockIndent(state, delta);
      final range = CollabTextRange.capture(state);
      await completion;
      if (mounted &&
          identical(widget.editorState, state) &&
          !state.isDisposed) {
        widget.onRangeChanged?.call(range);
        setState(() {});
      }
    } catch (error, stackTrace) {
      CollabDiagnostics.report(
        '文档块缩进失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DocCollab',
          context: ErrorDescription('changing collaborative block indentation'),
        ),
      );
    }
  }

  Future<void> _setAlignment(String alignment) async {
    final state = widget.editorState;
    final selection = state.selection;
    if (state.isDisposed || !state.editable || selection == null) return;
    final nodes = state.getNodesInSelection(selection);
    if (const {'justify', 'distributed'}.contains(alignment) && nodes.any((n) => n.delta == null)) {
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
    await state.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
    if (mounted && identical(widget.editorState, state)) setState(() {});
  }
}

final _blockLayoutToolbarItem = MobileToolbarItem.withMenu(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '对齐与缩进',
    child: KeyedSubtree(key: ValueKey('editor-shortcut-block-layout'), child: Icon(Icons.format_align_left, size: 27)),
  ),
  itemMenuBuilder: (_, editorState, service) => _BlockLayoutMenu(editorState: editorState),
);

/// 借用正文编辑器的类型菜单，格式面板可订阅本地转换结果，不持有文档资源。
class _BlockStyleMenu extends StatefulWidget {
  /// [editorState] 由页面拥有；[onRangeChanged] 在本地转换完成后接收同步结果快照，默认不通知。
  const _BlockStyleMenu({required this.editorState, this.onRangeChanged});

  /// 用于实时读取选区和执行类型事务的借用编辑器。
  final EditorState editorState;

  /// 格式面板用它接续自身转换后的选区；null结果表示转为不支持划词的类型。
  final ValueChanged<CollabTextRange?>? onRangeChanged;

  /// 创建菜单自己的披露与互斥状态，不释放借用编辑器。
  @override
  createState() => _BlockStyleMenuState();
}

class _BlockStyleMenuState extends State<_BlockStyleMenu> {
  /// 类型命令执行期间拒绝重复提交；所有退出路径均在 finally 恢复，不持有外部资源。
  bool _applyingStyle = false;

  // H1-H3 are the initial choices. Selecting H3 reveals H4, and each
  // subsequent highest visible heading reveals exactly one more level.
  int _maxHeadingLevel = 3;
  String? _activeNodeId;

  static const _paragraphStyle = _BlockStyleAction(blockType: ParagraphBlockKeys.type, label: '正文', text: 'T');

  static const _blockStyles = <_BlockStyleAction>[
    _BlockStyleAction(blockType: NumberedListBlockKeys.type, label: '有序列表', icon: Icons.format_list_numbered),
    _BlockStyleAction(blockType: BulletedListBlockKeys.type, label: '无序列表', icon: Icons.format_list_bulleted),
    _BlockStyleAction(blockType: TodoListBlockKeys.type, label: '待办列表', icon: Icons.check_box_outlined),
    _BlockStyleAction(blockType: 'code', label: '代码块', icon: Icons.data_object),
    _BlockStyleAction(blockType: QuoteBlockKeys.type, label: '引用块', icon: Icons.format_quote),
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
      oldWidget.editorState.selectionNotifier.removeListener(_onSelectionChanged);
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
          key: ValueKey('editor-block-${style.blockType}-${style.headingLevel ?? 0}'),
          tooltip: style.label,
          selected: selected,
          icon: style.icon == null
              ? Text(style.text!, style: const TextStyle(fontSize: 26, height: 1))
              : Icon(style.icon, size: 27),
          onPressed: () => _apply(style),
        );
      },
    );
  }

  /// 将 [style] 应用于点击时的当前选区；列表互换复用统一事务，保留层级、格式、勾选规则和焦点。
  /// 高亮容器、只读/销毁、无选区以及执行中的重复命令不执行；列表与非列表混选不部分切换。
  /// 借用 EditorState，await 后检查菜单仍挂载且编辑器未更换，避免迟到刷新。失败由本边界
  /// 记录原始异常和堆栈并交给 Flutter 错误报告；Future 在事务与菜单刷新结束后完成。
  /// 命令同步应用文档后立即捕获范围，异步结束只交付该快照，不接受等待期间的远端变化。
  Future<void> _apply(_BlockStyleAction style) async {
    final state = widget.editorState;
    final selection = state.selection;
    if (_applyingStyle || state.isDisposed || !state.editable || selection == null) {
      return;
    }
    final nodes = state.getNodesInSelection(selection);
    if (nodes.isEmpty || nodes.any((node) => node.type == csesCalloutBlockType)) {
      return;
    }
    _applyingStyle = true;
    try {
      const listTypes = {'numbered_list', 'bulleted_list', 'todo_list'};
      final completion = listTypes.contains(style.blockType) && nodes.any((node) => listTypes.contains(node.type))
          ? changeCollabListType(state, style.blockType)
          : state.formatNode(selection, (node) => _convertedNode(node, style.blockType, style.headingLevel));
      final range = CollabTextRange.capture(state);
      await completion;
      if (!mounted || widget.editorState != state || state.isDisposed) {
        return;
      }
      widget.onRangeChanged?.call(range);
      final level = style.headingLevel;
      setState(() {
        if (level != null && level >= 3 && level < 9) {
          _maxHeadingLevel = math.max(_maxHeadingLevel, level + 1);
        } else if (level == null || level < 3) {
          _maxHeadingLevel = 3;
        }
      });
    } catch (error, stackTrace) {
      CollabDiagnostics.report('文档列表类型切换失败', error: error, stackTrace: stackTrace, tag: 'DocCollab');
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

String _subscriptDigit(int value) =>
    const {1: '₁', 2: '₂', 3: '₃', 4: '₄', 5: '₅', 6: '₆', 7: '₇', 8: '₈', 9: '₉'}[value]!;

class _BlockStyleAction {
  const _BlockStyleAction({required this.blockType, required this.label, this.headingLevel, this.text, this.icon})
    : assert(text != null || icon != null);

  final String blockType;
  final int? headingLevel;
  final String label;
  final String? text;
  final IconData? icon;

  bool matches(Node node) {
    if (node.type != blockType) {
      return false;
    }
    return blockType != HeadingBlockKeys.type || node.attributes[HeadingBlockKeys.level] == headingLevel;
  }
}

class _InlineStyleMenu extends StatefulWidget {
  const _InlineStyleMenu({required this.editorState, required this.inlineStyleController});

  final EditorState editorState;
  final _InlineStyleController inlineStyleController;

  @override
  createState() => _InlineStyleMenuState();
}

/// 持有颜色面板状态；格式命令读取实时选区并处理完整异步错误，不拥有编辑器。
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
    _InlineStyleAction(key: AppFlowyRichTextKeys.bold, label: '加粗', icon: Icons.format_bold),
    _InlineStyleAction(key: AppFlowyRichTextKeys.italic, label: '斜体', icon: Icons.format_italic),
    _InlineStyleAction(key: AppFlowyRichTextKeys.underline, label: '下划线', icon: Icons.format_underlined),
    _InlineStyleAction(key: AppFlowyRichTextKeys.strikethrough, label: '删除线', icon: Icons.format_strikethrough),
    _InlineStyleAction(key: AppFlowyRichTextKeys.code, label: '行内代码', icon: Icons.code),
    _InlineStyleAction(key: csesSuperscriptAttribute, label: '上标', icon: Icons.superscript),
    _InlineStyleAction(key: csesSubscriptAttribute, label: '下标', icon: Icons.subscript),
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

  /// 在借用 [context] 中回显当前格式；点击命令时重新读取选区，避免使用构建阶段的旧路径。
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

    final currentTextColor = _currentColor(selection, AppFlowyRichTextKeys.textColor);
    final currentBackgroundColor = _currentColor(selection, AppFlowyRichTextKeys.backgroundColor);

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
            selected: !currentTextColor.isMixed && currentTextColor.value != null,
            icon: Icon(
              Icons.format_color_text,
              key: const ValueKey('editor-inline-text-color-icon'),
              size: 28,
              color: parseCollabBlockColor(currentTextColor.value),
            ),
            onPressed: () => setState(() => _colorPicker = _InlineColorTarget.text),
          );
        }
        if (index == _backgroundColorButtonIndex) {
          return _PopupIconButton(
            key: const ValueKey('editor-inline-background-color'),
            tooltip: '文字背景颜色',
            selected: !currentBackgroundColor.isMixed && currentBackgroundColor.value != null,
            icon: Icon(
              Icons.format_color_fill,
              key: const ValueKey('editor-inline-background-color-icon'),
              size: 28,
              color: parseCollabBlockColor(currentBackgroundColor.value),
            ),
            onPressed: () => setState(() => _colorPicker = _InlineColorTarget.background),
          );
        }
        final style = _styles[index < _textColorButtonIndex ? index : index - 2];
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
          onPressed: () {
            unawaited(_toggleStyle(style.key));
          },
        );
      },
    );
  }

  /// 用 [selection] 回显颜色；[target] 决定字色或浅色，共用选择器保留自定义色。
  Widget _buildColorPicker(Selection selection, _InlineColorTarget target) {
    final isBackground = target == _InlineColorTarget.background;
    final attribute = isBackground ? AppFlowyRichTextKeys.backgroundColor : AppFlowyRichTextKeys.textColor;
    return CollabColorPicker(
      keyPrefix: isBackground ? 'editor-background-color' : 'editor-text-color',
      horizontal: true,
      textColors: !isBackground,
      selection: _currentColor(selection, attribute),
      resetLabel: isBackground ? '清除背景色' : '默认颜色',
      onBack: () => setState(() => _colorPicker = null),
      onSelected: (value) => _applyColor(attribute, collabColorToEditor(value)),
    );
  }

  /// 汇总借用 [selection] 的 [attribute]；折叠位置读取后续输入格式。
  /// 比较等价CSS/ARGB颜色，混合选区不再与默认色混淆。
  CollabColorSelection _currentColor(Selection selection, String attribute) {
    if (selection.isCollapsed) {
      return CollabColorSelection(widget.inlineStyleController.value(attribute) as String?);
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    final values = <String?>[];
    for (final node in nodes) {
      final delta = node.delta;
      if (delta == null) continue;
      final start = node == nodes.first ? selection.startIndex : 0;
      final end = node == nodes.last ? selection.endIndex : delta.length;
      for (final operation in delta.slice(start, end)) {
        final value = operation.attributes?[attribute];
        values.add(value is String ? value : null);
      }
    }
    return CollabColorSelection.fromValues(values);
  }

  /// 设置 [attribute] 对应的字色或背景色；[color] 为既有调色板值，null 清除颜色。
  /// 点击时读取实时选区，折叠位置配置后续输入，范围选区复用现有格式事务；失败由共用边界报告。
  Future<void> _applyColor(String attribute, String? color) => _runFormatAction((state, selection) async {
    if (selection.isCollapsed) {
      await widget.inlineStyleController.setValue(attribute, color);
    } else {
      widget.inlineStyleController.clearAll();
      await formatCollabParagraphSelection(state, selection, {attribute: color});
    }
  });

  bool _isSelected(Selection selection, String attribute) {
    if (selection.isCollapsed) {
      return widget.inlineStyleController.value(attribute) == true;
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    return nodes.isNotEmpty &&
        nodes.allSatisfyInSelection(
          selection,
          (delta) => delta.everyAttributes((attributes) => attributes[attribute] == true),
        );
  }

  /// 切换实时选区的 [attribute] 格式；上下标互斥，空段落同时保存默认字符格式。
  /// 异步完成包含事务和面板回显，错误由共用边界报告，不缓存构建阶段选区。
  Future<void> _toggleStyle(String attribute) => _runFormatAction((state, selection) async {
    final isScript = attribute == csesSuperscriptAttribute || attribute == csesSubscriptAttribute;
    if (selection.isCollapsed) {
      final other = attribute == csesSuperscriptAttribute
          ? csesSubscriptAttribute
          : attribute == csesSubscriptAttribute
          ? csesSuperscriptAttribute
          : null;
      await widget.inlineStyleController.toggle(attribute, mutuallyExclusiveWith: other);
    } else {
      widget.inlineStyleController.clearAll();
      final other = attribute == csesSuperscriptAttribute ? csesSubscriptAttribute : csesSuperscriptAttribute;
      final next = !_isSelected(selection, attribute);
      if (!isScript) {
        await formatCollabParagraphSelection(state, selection, {attribute: next ? true : null});
      } else {
        await formatCollabParagraphSelection(state, selection, {other: null, attribute: next ? true : null});
      }
    }
  });

  /// 校验借用编辑器和实时选区后等待 [action]；允许界面显式不等待此完整错误处理边界。
  /// 当前只读/关闭/无选区时不执行，异常上报并显示重试提示，迟到结果不刷新新编辑器。
  Future<void> _runFormatAction(Future<void> Function(EditorState state, Selection selection) action) async {
    final state = widget.editorState;
    final selection = state.selection;
    if (state.isDisposed || !state.editable || selection == null) return;
    try {
      await action(state, selection);
      if (mounted && identical(state, widget.editorState)) setState(() {});
    } catch (error, stack) {
      CollabDiagnostics.report('文字格式修改失败', error: error, stackTrace: stack, tag: 'DocCollab');
      if (mounted && identical(state, widget.editorState)) {
        _showToolbarMessage(context, '格式修改失败，请重试');
      }
    }
  }
}

/// 行内颜色入口，二者共用色板组件但写入各自的字符属性。
enum _InlineColorTarget {
  /// 字符前景色。
  text,

  /// 字符背景色。
  background,
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
  const _InlineStyleAction({required this.key, required this.label, required this.icon});

  final String key;
  final String label;
  final IconData icon;
}

void _showUnsupportedMessage(BuildContext context, String label) {
  _showToolbarMessage(context, '$label 尚未进入当前 Rust/Yrs 协同 Schema');
}

void _showToolbarMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
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
    return Position(path: node.path, offset: offset.clamp(0, node.delta?.length ?? 0));
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
  /// 隔离借用 [state] 的正文输入和两类工具栏，保存稳定选区及原有输入样式供退场恢复。
  _EditorModalSession(this.state)
    : bookmark = state.selection == null ? null : _EditorSelectionBookmark(state, state.selection!),
      previousExtraInfo = state.selectionExtraInfo == null
          ? null
          : Map<Object?, Object?>.from(state.selectionExtraInfo!),
      previousStyle = Map<String, dynamic>.from(state.toggledStyle) {
    state.selectionExtraInfo = {
      ...?previousExtraInfo,
      selectionExtraInfoDisableMobileToolbarKey: true,
      selectionExtraInfoDisableFloatingToolbar: true,
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

  /// 在借用 [context] 仍允许恢复焦点时恢复 [appliedSelection] 或原稳定选区。
  /// null [context] 仅结束隔离；null [appliedSelection] 使用原选区与输入样式。
  /// 恢复事件暂时抑制划词浮栏，结束后仅归还本会话仍持有的附加选区信息。
  Future<void> finish(BuildContext? context, Selection? appliedSelection) async {
    if (state.isDisposed) return;
    state.selectionExtraInfo = previousExtraInfo;
    state.service.keyboardService?.enableShortcuts();
    if (context == null || !_canRestoreEditorFocus(context, state)) return;
    final selection = appliedSelection ?? bookmark?.resolve(state);
    // A deleted anchor must not silently resolve to a different block.
    if (selection == null) return;
    final restorationInfo = <Object?, Object?>{...?previousExtraInfo, selectionExtraInfoDisableFloatingToolbar: true};
    await _restoreEditorCaretAndKeyboard(context, state, selection, extraInfo: restorationInfo);
    if (!state.isDisposed && identical(state.selectionExtraInfo, restorationInfo)) {
      state.selectionExtraInfo = previousExtraInfo;
    }
    if (!state.isDisposed && appliedSelection == null && state.selection == selection) {
      for (final entry in previousStyle.entries) {
        state.updateToggledStyle(entry.key, entry.value);
      }
    }
  }
}

/// 在借用 [context]/[editorState] 上展示添加入口并保存稳定书签。
/// 嵌套宿主选择器退场后才恢复正文；取消不写入，权限或会话失效不恢复旧光标。
Future<void> showEditorAddBlockSheet(BuildContext context, EditorState editorState) async {
  if (editorState.isDisposed || !editorState.editable) return;
  if (editorState.selection == null) {
    _showToolbarMessage(context, '请先把光标放入正文');
    return;
  }
  final services = CollabRuntime.services;
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
          canUseHost: () => identical(CollabRuntime.services, services),
        );
      },
    );
    await route?.completed;
  } finally {
    await session.finish(
      context.mounted && identical(CollabRuntime.services, services) ? context : null,
      appliedSelection,
    );
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
        : await applyUrlBlockShortcut(editorState, current, blockType, source.url, mediaSource: source);
    if (context.mounted && nextSelection == null) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
    }
  } finally {
    await session.finish(context.mounted ? context : null, nextSelection);
  }
}

String _mediaTargetId(Node node) =>
    node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] as String? ?? node.id;

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

/// 在 [action] 的完整头部操作期间隔离正文输入，结束后恢复原稳定块选区。
/// [context] 与 [editorState] 均为借用对象；弹窗必须等待退场动画后完成。
/// [action] 的结果在正文选区恢复后返回，取消为null；异常仍恢复焦点后透传，销毁的编辑器不执行action。
/// [canRestore] 可在异步结束时拒绝恢复已失效会话的焦点；null沿用页面与编辑器存活检查。
/// [selectionAfterAction] 在操作完成后解析目标选区，供新插入正文恢复光标与键盘；
/// 未提供或返回null时恢复原稳定选区，回调不得修改编辑器。
Future<T?> runEditorHeaderAction<T>(
  BuildContext context,
  EditorState editorState,
  Future<T?> Function() action, {
  bool Function()? canRestore,
  Selection? Function()? selectionAfterAction,
}) async {
  if (editorState.isDisposed) return null;
  final session = _EditorModalSession(editorState);
  try {
    return await action();
  } finally {
    await session.finish(
      context.mounted && (canRestore?.call() ?? true) ? context : null,
      editorState.isDisposed ? null : selectionAfterAction?.call(),
    );
  }
}

bool _canRestoreEditorFocus(BuildContext context, EditorState state) =>
    context.mounted && !state.isDisposed && state.editable && ModalRoute.of(context)?.isCurrent != false;

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
  await editorState.updateSelectionWithReason(selection, reason: SelectionUpdateReason.uiEvent, extraInfo: extraInfo);
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
  if (!context.mounted || !_canRestoreEditorFocus(context, editorState) || editorState.selection != selection) {
    return;
  }
  await editorState.updateSelectionWithReason(selection, reason: SelectionUpdateReason.uiEvent, extraInfo: extraInfo);
}

Future<void> _waitForEditableSelectionTarget(EditorState editorState, Selection selection) async {
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

/// 完整块选择面板，借用编辑器和打开面板时捕获的稳定选区。
/// 支持的操作复用现有块命令；成功后返回目标选区，由外层在退场后恢复正文输入。
class _AddBlockSheet extends StatelessWidget {
  /// [editorState] 为借用编辑器，[bookmark] 是原始稳定位置，
  /// [canUseHost] 检查打开面板时的宿主会话是否仍有效，不持有业务资源。
  const _AddBlockSheet({required this.editorState, required this.bookmark, required this.canUseHost});

  /// 借用的正文状态，面板不释放。
  final EditorState editorState;

  /// 打开时保存的稳定选区，随远端重排解析。
  final _EditorSelectionBookmark bookmark;

  /// 原宿主会话有效性检查，失效面板不得调用新宿主选人。
  final bool Function() canUseHost;

  // The add/more sheet is the exhaustive block picker, unlike the compact T
  // menu that progressively discloses deep headings. Expose every heading
  // level supported by the collaborative schema so H7-H9 can be inserted
  // directly without first walking through H3-H8.
  static const _maxHeadingLevel = 9;

  /// 使用借用的 [context] 构建块入口；代码块与标题、列表复用同一插入及关闭流程。
  /// 返回面板 Widget，不持有或释放编辑器；未支持的入口继续显示占位提示。
  /// 在借用 [context] 中渲染可用块入口；插入按保存的稳定选区定位并等待事务完成。
  /// 在借用[context]中构建块/行内入口；用户选择调用宿主选择器并复用稳定插入位置。
  /// 表格直接创建2×2网格，插入前重查原始书签，权限/文档失效时不插入。
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
                const Text('添加', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
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
          const Divider(height: 0),
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
                            onTap: () => _applyAndClose(context, _BlockShortcut.heading(level)),
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
                        childAspectRatio: 0.8,
                        children: [
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-numbered-list'),
                            icon: Icons.format_list_numbered,
                            label: '有序列表',
                            onTap: () => _applyAndClose(context, const _BlockShortcut(NumberedListBlockKeys.type)),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-bulleted-list'),
                            icon: Icons.format_list_bulleted,
                            label: '无序列表',
                            onTap: () => _applyAndClose(context, const _BlockShortcut(BulletedListBlockKeys.type)),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-todo-list'),
                            icon: Icons.check_box_outlined,
                            label: '待办列表',
                            onTap: () => _applyAndClose(context, const _BlockShortcut(TodoListBlockKeys.type)),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-code-block'),
                            icon: Icons.data_object,
                            label: '代码块',
                            onTap: () => _applyAndClose(context, const _BlockShortcut(csesCodeBlockType)),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-quote'),
                            icon: Icons.format_quote,
                            label: '引用',
                            onTap: () => _applyAndClose(context, const _BlockShortcut(QuoteBlockKeys.type)),
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
                        childAspectRatio: 0.8,
                        children: [
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-image-block'),
                            icon: Icons.image_outlined,
                            label: '图片',
                            accent: const Color(0xFFF4B400),
                            tint: const Color(0xFFFFF8E1),
                            onTap: () => _requestUrlAndClose(context, ImageBlockKeys.type),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-link-block'),
                            icon: Icons.link,
                            label: '链接',
                            accent: const Color(0xFF2563EB),
                            tint: const Color(0xFFDBEAFE),
                            onTap: () => _requestUrlAndClose(context, csesLinkBlockType),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-video-block'),
                            icon: Icons.movie_outlined,
                            label: '视频',
                            accent: const Color(0xFF7C3AED),
                            tint: const Color(0xFFEDE9FE),
                            onTap: () => _requestUrlAndClose(context, csesVideoBlockType),
                          ),
                          for (final resource in const [
                            ('attachment', '附件', Icons.attach_file),
                            ('audio', '音频', Icons.audiotrack_outlined),
                            ('bookmark', '网页卡片', Icons.bookmark_border),
                            ('embed', '网页嵌入', Icons.language),
                            ('juejin-embed', '掘金', Icons.article_outlined),
                            ('figma-embed', 'Figma', Icons.design_services_outlined),
                          ])
                            _ActionShortcutTile(
                              key: ValueKey('editor-shortcut-${resource.$1}-block'),
                              icon: resource.$3,
                              label: resource.$2,
                              accent: const Color(0xFF2563EB),
                              tint: const Color(0xFFEFF6FF),
                              onTap: () => _requestUrlAndClose(context, resource.$1),
                            ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-table'),
                            icon: Icons.table_chart_outlined,
                            label: '表格',
                            accent: const Color(0xFF14B8A6),
                            tint: const Color(0xFFCCFBF1),
                            onTap: () async {
                              if (!canUseHost()) return;
                              final captured = bookmark.resolve(editorState);
                              if (captured == null) return;
                              final selection = await insertCollabTable(editorState, captured);
                              if (context.mounted && selection != null) {
                                Navigator.pop<Selection>(context, selection);
                              }
                            },
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-callout'),
                            icon: Icons.view_stream_outlined,
                            label: '高亮块',
                            accent: const Color(0xFFF97316),
                            tint: const Color(0xFFFFEDD5),
                            onTap: () async {
                              final capturedSelection = bookmark.resolve(editorState);
                              if (capturedSelection == null) return;
                              final selection = await insertCollabCallout(editorState, capturedSelection);
                              if (context.mounted && selection != null) {
                                Navigator.pop<Selection>(context, selection);
                              }
                            },
                          ),
                          if (CollabRuntime.services.pickMeetingReference != null)
                            _ActionShortcutTile(
                              key: const ValueKey('editor-shortcut-meeting'),
                              icon: Icons.groups_outlined,
                              label: '会议',
                              onTap: () async {
                                final services = CollabRuntime.services;
                                try {
                                  final reference = await pickHostMeetingReference(context, editorState);
                                  if (!context.mounted || reference == null) {
                                    return;
                                  }
                                  final selection = bookmark.resolve(editorState);
                                  if (selection == null) {
                                    _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
                                    return;
                                  }
                                  final landing = await insertCollabMeeting(editorState, selection, {
                                    'meetingId': reference.meetingId,
                                    'title': reference.title,
                                    'number': reference.number,
                                  });
                                  if (context.mounted && landing != null) {
                                    Navigator.pop<Selection>(context, landing);
                                  } else if (context.mounted && editorState.editable) {
                                    _showToolbarMessage(context, '会议引用无效或插入位置已变化');
                                  }
                                } catch (error, stack) {
                                  services.report('插入会议引用失败', error, stack, 'DocCollab');
                                  if (context.mounted && identical(services, CollabRuntime.services)) {
                                    _showToolbarMessage(context, '插入失败，请重试');
                                  }
                                }
                              },
                            ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-formula'),
                            icon: Icons.functions,
                            label: '公式',
                            onTap: () async {
                              try {
                                final latex = await showCollabFormulaInput(context, editorState);
                                if (!context.mounted || latex == null) return;
                                final selection = bookmark.resolve(editorState);
                                if (selection == null) {
                                  _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
                                  return;
                                }
                                final landing = await insertCollabFormula(editorState, selection, latex);
                                if (context.mounted && landing != null) {
                                  Navigator.pop<Selection>(context, landing);
                                }
                              } catch (error, stack) {
                                CollabDiagnostics.report('插入公式失败', error: error, stackTrace: stack, tag: 'DocCollab');
                                if (context.mounted) {
                                  _showToolbarMessage(context, '插入失败，请重试');
                                }
                              }
                            },
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-mention-more'),
                            icon: Icons.alternate_email,
                            label: '@用户',
                            onTap: () => _insertMention(context),
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-inline-formula'),
                            icon: Icons.functions,
                            label: '行内公式',
                            onTap: () async {
                              try {
                                final latex = await showCollabFormulaInput(context, editorState);
                                if (!context.mounted || latex == null) return;
                                final selection = bookmark.resolve(editorState);
                                if (selection == null) {
                                  _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
                                  return;
                                }
                                final landing = await insertCollabInlineFormula(editorState, selection, latex);
                                if (context.mounted && landing != null) {
                                  Navigator.pop<Selection>(context, landing);
                                } else if (context.mounted) {
                                  _showToolbarMessage(context, '请选择同一段正文中的位置，公式内容不能为空');
                                }
                              } catch (error, stack) {
                                CollabDiagnostics.report('插入行内公式失败', error: error, stackTrace: stack, tag: 'DocCollab');
                                if (context.mounted) {
                                  _showToolbarMessage(context, '插入失败，请重试');
                                }
                              }
                            },
                          ),
                          _ActionShortcutTile(
                            key: const ValueKey('editor-shortcut-divider'),
                            icon: Icons.horizontal_rule,
                            label: '分割线',
                            accent: const Color(0xFF6366F1),
                            tint: const Color(0xFFE0E7FF),
                            onTap: () async {
                              final selection = bookmark.resolve(editorState);
                              if (selection == null) {
                                _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
                                return;
                              }
                              try {
                                final landing = await insertCollabDivider(editorState, selection);
                                if (context.mounted && landing != null) {
                                  Navigator.pop<Selection>(context, landing);
                                }
                              } catch (error, stack) {
                                CollabDiagnostics.report('插入分割线失败', error: error, stackTrace: stack, tag: 'DocCollab');
                                if (context.mounted) {
                                  _showToolbarMessage(context, '插入失败，请重试');
                                }
                              }
                            },
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

  /// 在借用[context]的更多面板内打开人员选择；按原书签插入，父面板退场后恢复正文。
  /// 子面板期间正文/身份变化拒绝提交；取消保留父面板与原选区，失败报告并提示。
  Future<void> _insertMention(BuildContext context) async {
    if (!canUseHost()) return;
    final services = CollabRuntime.services;
    final captured = bookmark.resolve(editorState);
    if (captured == null || !captured.isSingle) return;
    final node = editorState.getNodeAtPath(captured.start.path);
    if (node?.delta == null || node!.type == 'code') {
      _showToolbarMessage(context, '此位置不支持用户提及');
      return;
    }
    final original = Delta.fromJson(node.delta!.toJson());
    try {
      final user = await pickHostMentionUser(context, editorState);
      if (!context.mounted || user == null) return;
      final selection = bookmark.resolve(editorState);
      if (selection == null || editorState.getNodeAtPath(selection.start.path)?.delta != original) {
        _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
        return;
      }
      final landing = await insertCollabUserMention(editorState, selection, user);
      if (context.mounted && landing != null) {
        Navigator.pop<Selection>(context, landing);
      }
    } catch (error, stack) {
      services.report('插入用户提及失败', error, stack, 'DocCollab');
      if (context.mounted && identical(CollabRuntime.services, services)) {
        _showToolbarMessage(context, '插入失败，请重试');
      }
    }
  }

  /// 按稳定块标记解析插入位置，将 [shortcut] 应用于借用的编辑器。
  /// [context] 属于当前面板；位置失效时提示且保持面板，成功后关闭并返回目标选区。
  /// Future 在块事务和关闭请求完成后结束，退场与焦点恢复由外层负责；事务异常透传。
  Future<void> _applyAndClose(BuildContext context, _BlockShortcut shortcut) async {
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
      Navigator.pop<Selection>(context, editorState.selection ?? capturedSelection);
    }
  }

  Future<void> _requestUrlAndClose(BuildContext context, String blockType) async {
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
        : await applyUrlBlockShortcut(editorState, current, blockType, source.url, mediaSource: source);
    if (context.mounted && nextSelection != null) {
      Navigator.pop<Selection>(context, nextSelection);
    } else if (context.mounted) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
    }
  }
}

class _BlockShortcut {
  const _BlockShortcut(this.blockType) : headingLevel = null;

  const _BlockShortcut.heading(int level) : blockType = HeadingBlockKeys.type, headingLevel = level;

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
      (isCollabResourceType(blockType) && !isCollabResourceUrl(blockType, url))) {
    return null;
  }
  final targetPath = selection.start.path;
  final targetNode = editorState.getNodeAtPath(targetPath);
  if (targetNode == null) {
    return null;
  }

  final mediaNode = _urlBackedNode(blockType, url.trim(), mediaSource: mediaSource);
  // This is a new resource, including when replacing an empty paragraph.
  // Without an explicit identity the adapter's positional fallback treats it
  // as a conversion of that paragraph; Rust then skips initial resource props.
  mediaNode.updateAttributes({AppFlowyBlockEditorAdapter.collabBlockIdAttribute: mediaNode.id});
  final sourceIsEmpty = targetNode.delta?.toPlainText().isEmpty == true;
  final insertPath = sourceIsEmpty ? targetPath : targetPath.next;
  final paragraphPath = insertPath.next;
  final paragraphNode = _emptyNode(ParagraphBlockKeys.type, null);
  final nextSelection = Selection.single(path: paragraphPath, startOffset: 0);

  final transaction = editorState.transaction;
  transaction.insertNodes(insertPath, [mediaNode, paragraphNode], deepCopy: false);
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

/// Creates a detached resource node for validated [blockType] and HTTP(S) [url].
/// Optional borrowed [mediaSource] contributes uploaded file metadata; null means
/// a link-only source. Link cards use default full width and natural height, with
/// no saved host-name title masking fetched metadata. Returns a node without
/// inserting it or performing network requests; the caller owns insertion.
Node _urlBackedNode(String blockType, String url, {EditorMediaSource? mediaSource}) {
  if (blockType == ImageBlockKeys.type) {
    return Node(
      type: ImageBlockKeys.type,
      attributes: {ImageBlockKeys.url: url, ImageBlockKeys.align: 'center', csesBlockIndentAttribute: 0},
    );
  }
  return Node(
    type: blockType,
    attributes: {
      if (isCollabResourceType(blockType))
        ...CollabResource.fromValues({
          if (blockType == 'attachment')
            'name': mediaSource?.file?.name ?? Uri.parse(url).pathSegments.lastOrNull ?? '附件',
          if (blockType == 'audio') 'sourceType': mediaSource?.file == null ? 'link' : 'local',
          if (mediaSource?.file != null && {'audio', 'attachment'}.contains(blockType)) ...{
            'name': mediaSource!.file!.name,
            'size': mediaSource.file!.size,
            if (blockType == 'attachment') 'type': mediaSource.file!.mimeType,
          },
          if ({'embed', 'figma-embed', 'juejin-embed'}.contains(blockType)) ...{'wr': 100},
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
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
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
  if (editorState.isDisposed || !editorState.editable || selection.start.path.isEmpty) {
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
    await editorState.formatNode(nodeSelection, (node) => _convertedNode(node, blockType, headingLevel));
    return true;
  }

  final insertPath = targetPath.next;
  final transaction = editorState.transaction
    ..insertNode(insertPath, _emptyNode(blockType, headingLevel), deepCopy: false)
    ..afterSelection = Selection.single(path: insertPath, startOffset: 0);
  await editorState.apply(transaction);
  return true;
}

/// 将借用 [node] 转为 [blockType]，[headingLevel] 仅标题使用，null 按一级。
/// 保留正文及段落默认格式/下一段设置；代码使用独立输入规则，不继承段落字段。
/// 返回新节点，身份由适配器类型转换链处理，不创建资源。
Node _convertedNode(Node node, String blockType, int? headingLevel) {
  final collabBlockId = node.attributes['cses_collab_block_id'];
  final alignment = node.attributes[blockComponentAlign] as String? ?? 'left';
  final keepsIndent =
      blockType == BulletedListBlockKeys.type ||
      blockType == NumberedListBlockKeys.type ||
      blockType == TodoListBlockKeys.type;
  final attributes = <String, Object>{
    if (blockType != 'code') ...{
      for (final key in collabParagraphKeys)
        if (key != 'heading' && node.attributes[paragraphPropertyAttribute(key)] is String)
          paragraphPropertyAttribute(key): node.attributes[paragraphPropertyAttribute(key)] as String,
      paragraphPropertyAttribute('heading'): blockType == HeadingBlockKeys.type
          ? '{"value":${(headingLevel ?? 1).clamp(1, 9)}}'
          : '{"value":null}',
    },
    blockComponentDelta: (node.delta ?? Delta()).toJson(),
    blockComponentAlign: alignment,
    csesBlockIndentAttribute: keepsIndent ? (node.attributes[csesBlockIndentAttribute] as int? ?? 0).clamp(0, 6) : 0,
    if (blockType == HeadingBlockKeys.type) HeadingBlockKeys.level: (headingLevel ?? 1).clamp(1, 9),
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
      if (blockType == HeadingBlockKeys.type) HeadingBlockKeys.level: (headingLevel ?? 1).clamp(1, 9),
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
    return Text(label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700));
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
        spacing: 5,
        children: [
          Container(
            decoration: BoxDecoration(color: const Color(0xFFF6F7F9), borderRadius: BorderRadius.circular(14)),
            alignment: Alignment.center,
            width: 52,
            height: 52,
            child: Text('H$level', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500)),
          ),
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
                    decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(14)),
                    child: Icon(icon, color: enabled ? accent : accent.withValues(alpha: 0.78), size: 28),
                  ),
                ),
                if (!enabled)
                  const Positioned(right: 5, top: 4, child: Icon(Icons.schedule, size: 12, color: Color(0xFF9CA3AF))),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: enabled ? const Color(0xFF111827) : const Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}
