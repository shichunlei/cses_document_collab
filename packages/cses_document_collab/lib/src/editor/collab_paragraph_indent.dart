import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;

/// 返回 [node] 是否使用普通文本段的平面缩进；列表继续使用既有独立通道。
bool supportsCollabTextIndent(Node node) => const {
  ParagraphBlockKeys.type,
  HeadingBlockKeys.type,
  QuoteBlockKeys.type,
}.contains(node.type);

/// 读取借用 [node] 的原始缩进；缺失、负数及非有限值回退零。
/// 保留超过8级的已有数据，不在读取或渲染时裁剪；列表兄弟可用独立深度投影。
double collabParagraphDepth(Node node) {
  final raw =
      readCollabParagraph(node).values['depth'] ??
      node.attributes[csesBlockIndentAttribute];
  final depth = raw is num ? raw.toDouble() : double.tryParse('$raw');
  return depth != null && depth.isFinite && depth >= 0 ? depth : 0;
}

/// 返回借用 [state] 当前选区能否整体增减 [delta]（仅-1/+1），不改变文档或选区。
/// 普通文本段遵守8级上限和首目标前兄弟深度+1；减少时零级保持零级。
/// 全列表选区沿用既有列表能力，跨父容器和混合列表/正文暂不接管。
bool canChangeCollabBlockIndent(EditorState state, int delta) {
  if (delta != -1 && delta != 1) return false;
  final nodes = _textTargets(state);
  if (nodes.isEmpty) return canChangeCollabListIndent(state, delta);
  final first = collabParagraphDepth(nodes.first);
  if (delta < 0) return first > 0;
  final previous = nodes.first.previous;
  return first + 1 <= 8 &&
      first + 1 <=
          (previous == null ? 0 : collabParagraphDepth(previous)) + 1 &&
      nodes.every((node) => collabParagraphDepth(node) < 8);
}

/// 在借用 [state] 的当前选区整体增减 [delta]（-1/+1），返回是否产生事务。
/// 段落、标题和引用仅修改depth，保留标题、文字、格式、原选区方向及类型；
/// 一次操作对应一次撤销，逆补丁保存稳定身份，远端重排后仍定位原块。
/// 不满足上限/兄弟/权限/范围条件时不部分写入；列表沿用独立实现。
/// Future在应用后完成；不持有额外资源，异常交调用边界处理。
Future<bool> changeCollabBlockIndent(EditorState state, int delta) async {
  if (!canChangeCollabBlockIndent(state, delta)) return false;
  final nodes = _textTargets(state);
  if (nodes.isEmpty) return changeCollabListIndent(state, delta);
  final key = paragraphPropertyAttribute('depth');
  final transaction = state.transaction;
  for (final node in nodes) {
    final depth = collabParagraphDepth(node);
    if (delta < 0 && depth == 0) continue;
    final target =
        node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] ??
        node.id;
    transaction.add(
      UpdateOperation(
        node.path,
        {
          key: jsonEncode({'value': depth + delta}),
          collabParagraphTargetAttribute: target,
        },
        {key: node.attributes[key], collabParagraphTargetAttribute: target},
      ),
    );
  }
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  transaction.afterSelection = state.selection;
  await state.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 普通文本段的硬件Tab入口，放在标准结构缩进前；不处理表格导航或代码Tab。
/// 借用编辑器，异步事务在诊断边界等待，不创建监听或可释放资源。
final collabParagraphTabCommand = CommandShortcutEvent(
  key: 'cses-text-tab',
  command: 'tab',
  getDescription: () => '增加文本段缩进',
  handler: (state) => _handleTab(state, 1),
);

/// 普通文本段的Shift+Tab入口，零级保持原块类型，不改为正文或嵌套子块。
final collabParagraphShiftTabCommand = CommandShortcutEvent(
  key: 'cses-text-shift-tab',
  command: 'shift+tab',
  getDescription: () => '减少文本段缩进',
  handler: (state) => _handleTab(state, -1),
);

/// 在借用 [state] 的普通文本段消费 [delta] 对应Tab；表格内文字留给表格命令。
KeyEventResult _handleTab(EditorState state, int delta) {
  final nodes = _textTargets(state);
  if (nodes.isEmpty) return KeyEventResult.ignored;
  for (
    Node? ancestor = nodes.first.parent;
    ancestor != null;
    ancestor = ancestor.parent
  ) {
    if (collabTableTypes.contains(ancestor.type)) return KeyEventResult.ignored;
  }
  if (canChangeCollabBlockIndent(state, delta)) {
    unawaited(_applyTab(state, delta));
  }
  return KeyEventResult.handled;
}

/// 等待借用 [state] 的 [delta] 缩进事务；失败保留错误及堆栈，避免后台Future静默失败。
Future<void> _applyTab(EditorState state, int delta) async {
  try {
    await changeCollabBlockIndent(state, delta);
  } catch (error, stack) {
    EditorCommandContext.report(
      state,
      '文本段缩进失败',
      error: error,
      stackTrace: stack,
    );
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack, library: 'DocCollab'),
    );
  }
}

/// 返回借用 [state] 中同父容器的普通文字叶块；无效、只读、混选或越界返回空。
List<Node> _textTargets(EditorState state) {
  if (state.isDisposed || !state.editable) return const [];
  final selection = state.selection;
  if (selection == null) return const [];
  final nodes = state.getNodesInSelection(selection.normalized);
  if (nodes.isEmpty ||
      nodes.any(
        (node) =>
            !supportsCollabTextIndent(node) ||
            node.children.isNotEmpty ||
            node.delta == null ||
            node.parent != nodes.first.parent,
      )) {
    return const [];
  }
  for (final position in [selection.start, selection.end]) {
    final node = state.getNodeAtPath(position.path);
    if (node == null ||
        position.offset < 0 ||
        position.offset > node.delta!.length) {
      return const [];
    }
  }
  return nodes;
}
