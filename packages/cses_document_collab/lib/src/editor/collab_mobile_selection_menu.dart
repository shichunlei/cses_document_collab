import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/editor_selection_actions.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_text_range.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 移动正文的划词菜单，复用 AppFlowy 选区定位、拖动结束和滚动后的浮栏生命周期。
/// 编辑模式提供剪贴板、格式、文字链接和公式转换，只读仅复制与全选；不依赖键盘显示。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_mobile_selection_menu.dart';
/// final state = EditorState.blank();
/// final scroll = EditorScrollController(editorState: state);
/// final editor = CollabMobileSelectionMenu(editorState: state, scrollController: scroll,
///   child: AppFlowyEditor(editorState: state, editorScrollController: scroll));
/// // 从树中移除 editor 后，由创建方依次 scroll.dispose()、state.dispose()。
/// ```
class CollabMobileSelectionMenu extends StatefulWidget {
  /// [key] 控制身份与状态复用，[editorState]/[scrollController] 均由页面创建和释放。
  /// [child] 为使用同一滚动控制器的编辑器；[enabled] 默认 true，未初始化时传 false。
  const CollabMobileSelectionMenu({
    super.key,
    required this.editorState,
    required this.scrollController,
    required this.child,
    this.enabled = true,
  });

  /// 必填的借用编辑器，操作前及异步返回后重新核对存活、选区和编辑权限。
  final EditorState editorState;

  /// 必填的借用滚动控制器；须与 child 内编辑器共用，不由本组件释放。
  final EditorScrollController scrollController;

  /// 必填正文组件，桌面平台直接显示它。
  final Widget child;

  /// 是否允许展示菜单，默认 true；初始化期间为 false。
  final bool enabled;

  /// 创建串行操作状态，不拥有文档、连接或滚动资源。
  @override
  createState() => _CollabMobileSelectionMenuState();
}

/// 一次只处理一个菜单动作，异常在菜单边界报告，面板持有稳定选区快照。
class _CollabMobileSelectionMenuState extends State<CollabMobileSelectionMenu> {
  bool _busy = false;

  /// 在借用 [context] 中挂载浮栏；编辑器更换时用身份 key 完整迁移上游选区/滚动监听。
  @override
  Widget build(BuildContext context) {
    if (!widget.enabled ||
        !const {
          TargetPlatform.android,
          TargetPlatform.iOS,
        }.contains(defaultTargetPlatform)) {
      return widget.child;
    }
    return MobileFloatingToolbar(
      key: ObjectKey(widget.scrollController),
      editorState: widget.editorState,
      editorScrollController: widget.scrollController,
      floatingToolbarHeight: 44,
      toolbarBuilder: _buildMenu,
      child: widget.child,
    );
  }

  /// 使用 [overlayContext] 和全局 [anchor] 构建系统样式菜单；[close] 归还上游浮层。
  /// 仅捕获受支持正文，跨单元格、容器、未知占位及代码选区不显示菜单。
  Widget _buildMenu(
    BuildContext overlayContext,
    Offset anchor,
    VoidCallback close,
  ) {
    final state = widget.editorState;
    final range = CollabTextRange.capture(state, allowCollapsed: true);
    if (range == null || _busy) return const SizedBox.shrink();
    final expanded = state.selection?.isCollapsed == false;
    return ListenableBuilder(
      listenable: Listenable.merge([
        state.editableNotifier,
        CollabBlockLocks.of(state),
      ]),
      builder: (context, _) {
        final editable =
            state.editable &&
            (state.selection == null || state.canInputAt(state.selection));
        return AdaptiveTextSelectionToolbar.buttonItems(
          key: const ValueKey('editor-selection-menu'),
          anchors: TextSelectionToolbarAnchors(primaryAnchor: anchor),
          buttonItems: [
            if (expanded) _button('复制', () => _copy(state, range), close),
            if (editable && expanded)
              _button('剪切', () => _copy(state, range, cut: true), close),
            if (editable) _button('粘贴', () => _paste(state, range), close),
            _button('全选', () => _selectAll(state), close),
            if (editable &&
                expanded &&
                range.hasText &&
                EditorCommandContext.of(
                  state,
                ).configuration.inlineFormats.isNotEmpty)
              _button(
                '格式',
                () => _withRange(
                  state,
                  range,
                  () => showEditorSelectionFormats(this.context, state),
                ),
                close,
              ),
            if (editable &&
                range.canConvert &&
                EditorCommandContext.of(
                  state,
                ).configuration.allowsFormat(AppFlowyRichTextKeys.href))
              _button(
                '链接',
                () => _withRange(
                  state,
                  range,
                  () => showEditorTextLink(this.context, state),
                ),
                close,
              ),
            if (editable &&
                range.canConvert &&
                EditorCommandContext.of(
                  state,
                ).configuration.allowsFormat('cses_inline_latex'))
              _button(
                '转行内公式',
                () => _withRange(
                  state,
                  range,
                  () => showEditorSelectionFormula(this.context, state),
                ),
                close,
              ),
          ],
        );
      },
    );
  }

  /// 在借用 [state] 的 [range] 仍有效且可编辑时等待 [action]；旧浮栏不得改写远端更新后的文字。
  Future<void> _withRange(
    EditorState state,
    CollabTextRange range,
    Future<void> Function() action,
  ) async {
    if (!mounted ||
        !identical(state, widget.editorState) ||
        state.isDisposed ||
        !state.editable ||
        range.resolve(state) == null) {
      return;
    }
    await action();
  }

  /// 用 [label] 标注动作，[action] 必须等待全部异步工作，[close] 在动作开始前移除浮栏。
  ContextMenuButtonItem _button(
    String label,
    Future<void> Function() action,
    VoidCallback close,
  ) => ContextMenuButtonItem(
    label: label,
    onPressed: () {
      if (_busy) return;
      close();
      unawaited(_run(action));
    },
  );

  /// 串行等待借用 [action]，处理异常并检查组件存活；迟到动作不重新打开浮层。
  Future<void> _run(Future<void> Function() action) async {
    _busy = true;
    try {
      await action();
    } catch (error, stack) {
      EditorCommandContext.of(
        widget.editorState,
      ).services.report('划词操作失败', error, stack, 'DocCollab');
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
      }
    } finally {
      _busy = false;
    }
  }

  /// 复制借用 [state] 中稳定 [range] 的纯文本；[cut] 默认 false，为 true 时复制成功才删除。
  /// 剪贴板失败不删除；异步期间原文、格式、权限或组件身份变化均取消删除。
  Future<void> _copy(
    EditorState state,
    CollabTextRange range, {
    bool cut = false,
  }) async {
    if (range.resolve(state) == null || (cut && !state.editable)) return;
    await AppFlowyClipboard.setData(text: range.text);
    if (!cut ||
        !mounted ||
        !identical(widget.editorState, state) ||
        state.isDisposed ||
        !state.editable) {
      return;
    }
    final selection = range.resolve(state);
    if (selection == null) return;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.deleteSelection(selection);
  }

  /// 在借用 [state] 的稳定 [range] 上粘贴系统纯文本；读取剪贴板后重新校验权限和目标。
  /// 同级叶子正文以单个事务替换，保留前后原格式并按换行新建段落；一次撤销恢复整个范围。
  Future<void> _paste(EditorState state, CollabTextRange range) async {
    final paste = EditorCommandContext.of(state).pastePlainText;
    if (paste != null) {
      final selection = range.resolve(state);
      if (selection != null) {
        state.selection = selection;
        await paste();
      }
      return;
    }
    final data = await AppFlowyClipboard.getData();
    if (!mounted ||
        !identical(widget.editorState, state) ||
        state.isDisposed ||
        !state.editable ||
        data.text == null ||
        data.text!.isEmpty) {
      return;
    }
    final selection = range.resolve(state);
    if (selection == null) return;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    final targets = state.getNodesInSelection(selection);
    final lines = data.text!
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final prefix = targets.first.delta!.slice(0, selection.start.offset);
    final suffix = targets.last.delta!.slice(selection.end.offset);
    final first = Delta()
      ..addAll(prefix)
      ..insert(lines.first);
    if (lines.length == 1) first.addAll(suffix);
    final inserted = <Node>[];
    for (var i = 1; i < lines.length; i++) {
      final delta = Delta()..insert(lines[i]);
      if (i == lines.length - 1) delta.addAll(suffix);
      inserted.add(paragraphNode(delta: delta));
    }
    final transaction = state.transaction
      ..updateNode(targets.first, {'delta': first.toJson()});
    if (targets.length > 1) transaction.deleteNodes(targets.skip(1).toList());
    if (inserted.isNotEmpty) {
      transaction.insertNodes(targets.first.path.next, inserted);
    }
    final landingPath = [...targets.first.path];
    landingPath[landingPath.length - 1] += inserted.length;
    transaction.afterSelection = Selection.single(
      path: landingPath,
      startOffset: lines.length == 1
          ? prefix.length + lines.single.length
          : lines.last.length,
    );
    await state.apply(transaction, skipHistoryDebounce: true);
  }

  /// 在借用 [state] 中选择整篇可定位正文；无已挂载末端时不改变当前范围。
  Future<void> _selectAll(EditorState state) async {
    if (state.isDisposed) return;
    final last = state.getLastSelectable();
    if (last == null) return;
    state.selectionType = SelectionType.inline;
    state.selection = Selection(
      start: Position(path: [0]),
      end: last.$2.end(last.$1),
    );
  }
}
