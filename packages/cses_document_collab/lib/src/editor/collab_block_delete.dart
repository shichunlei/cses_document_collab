import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 硬件 Backspace/Shift+Backspace 的协同入口，置于标准命令前。
/// 行首列表先退级，随后保护容器边界，再处理前置资源删除；不接管行内文字和范围删除。
/// 编辑器命令回调必须同步返回 KeyEventResult，事务由私有异步异常边界等待并上报失败。
/// 借用 EditorState，无额外监听或资源；软键盘通过同规则的拦截器处理。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
/// final state = EditorState.blank(); // 宿主负责 dispose。
/// final editor = AppFlowyEditor(editorState: state, commandShortcutEvents: [
///   collabBlockBackspaceCommand, ...standardCommandShortcutEvents,
/// ]);
/// ```
final collabBlockBackspaceCommand = CommandShortcutEvent(
  key: 'cses-block-backspace',
  command: 'backspace, shift+backspace',
  getDescription: () => '列表退级或删除前置资源块',
  handler: (state) {
    if (state.isDisposed || !state.editable) {
      return KeyEventResult.ignored;
    }
    if (canOutdentCollabListAtStart(state)) {
      unawaited(_runBackspaceTransaction(state, outdent: true));
      return KeyEventResult.handled;
    }
    if (isProtectedCalloutBoundary(state) ||
        isProtectedUnsupportedBlockBoundary(state)) {
      return KeyEventResult.handled;
    }
    if (!canDeletePreviousUrlBackedBlock(state)) {
      return KeyEventResult.ignored;
    }
    unawaited(_runBackspaceTransaction(state, outdent: false));
    return KeyEventResult.handled;
  },
);

/// 移动 IME 删除拦截器，统一列表退级、容器边界保护和相邻媒体删除的优先级。
/// AppFlowy 在调用前移除行首占位符；退格占位符表现为逻辑位置 0 的折叠删除范围。
/// 非折叠删除和正在组合的候选文字交给原输入链，避免把实际删字误判成退级。
/// 不拥有编辑器或键盘服务；创建方在服务挂载后注册，换 EditorState/退出时注销。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
/// final state = EditorState.blank();
/// // 将 state 交给 AppFlowyEditor；在首帧服务挂载后注册。
/// final service = state.service.keyboardService!;
/// final interceptor = CollabBlockBackspaceInterceptor();
/// service.registerInterceptor(interceptor);
/// // 所属 Widget dispose 时，先注销再释放自己创建的编辑器。
/// service.unregisterInterceptor(interceptor);
/// state.dispose();
/// ```
class CollabBlockBackspaceInterceptor
    extends AppFlowyKeyboardServiceInterceptor {
  /// 创建无状态拦截器；不自动注册服务，不拥有 EditorState 或可释放资源。
  CollabBlockBackspaceInterceptor();

  /// 处理已去除占位符的 [deletion]，借用 [editorState] 完成结构事务后返回 true。
  /// 列表行首折叠删除优先退级；前向删字、候选词删除、范围选区及普通行内删除返回 false。
  /// 非列表沿用容器边界保护与媒体删除。只读/销毁时不执行；异常通过 Future 交给 IME 边界。
  @override
  Future<bool> interceptDelete(
    TextEditingDeltaDeletion deletion,
    EditorState editorState,
  ) async {
    if (editorState.isDisposed || !editorState.editable) {
      return false;
    }
    if (canOutdentCollabListAtStart(editorState)) {
      if (!deletion.deletedRange.isCollapsed ||
          deletion.deletedRange.start != 0 ||
          (deletion.composing.isValid && !deletion.composing.isCollapsed)) {
        return false;
      }
      return outdentCollabListAtStart(editorState);
    }
    if ((isProtectedCalloutBoundary(editorState) ||
            isProtectedUnsupportedBlockBoundary(editorState)) &&
        deletion.deletedRange.isCollapsed &&
        deletion.deletedRange.start == 0) {
      return true;
    }
    if (!canDeletePreviousUrlBackedBlock(editorState)) {
      return false;
    }
    return deletePreviousUrlBackedBlock(editorState);
  }
}

/// 在同步硬件命令边界等待借用 [state] 的事务；[outdent] 为 true 时退级列表，否则删除前置资源。
/// 不持有资源或跨回调保存选区。非预期异常保留原异常与堆栈，统一 CollabDiagnostics.report 并交 FlutterError，
/// 使同步快捷键派发之外的异步失败可观测；不重复弹出用户提示。
Future<void> _runBackspaceTransaction(
  EditorState state, {
  required bool outdent,
}) async {
  try {
    if (outdent) {
      await outdentCollabListAtStart(state);
    } else {
      await deletePreviousUrlBackedBlock(state);
    }
  } catch (error, stackTrace) {
    CollabDiagnostics.report(
      '文档退格事务失败',
      error: error,
      stackTrace: stackTrace,
      tag: 'DocCollab',
    );
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'DocCollab',
        context: ErrorDescription('handling collaborative Backspace'),
      ),
    );
  }
}

/// 返回借用的 [editorState] 当前折叠光标是否应删除前置资源；要求偏移 0，且存在前置媒体、分割线或公式。
/// 只读、销毁、无选区/Delta 或其他前项返回 false；不执行删除或拥有资源。
bool canDeletePreviousUrlBackedBlock(EditorState editorState) {
  if (editorState.isDisposed || !editorState.editable) {
    return false;
  }
  final selection = editorState.selection;
  if (selection == null ||
      !selection.isCollapsed ||
      selection.start.offset != 0) {
    return false;
  }
  final currentNode = editorState.getNodeAtPath(selection.start.path);
  if (currentNode?.delta == null) {
    return false;
  }
  final previousNode = currentNode!.previous;
  return previousNode != null && _isUrlBackedBlock(previousNode.type);
}

/// Deletes the resource immediately before a caret at text offset zero.
///
/// [editorState] 为借用的编辑器；仅在前置资源、分割线或公式可删除时执行。完成事务返回 true，
/// 不满足条件返回 false；异常通过 Future 传播，资源的组件生命周期由编辑器负责。
/// 分割线与公式删除单独封闭撤销记录，避免与插入/相邻正文输入合并。
/// The current text block is deliberately retained. Removing its previous
/// sibling shifts it onto the deleted block's path, so [previousNode.path] is
/// also the correct post-transaction caret path. This keeps the software
/// keyboard attached and lets the normal adapter publish one collaborative
/// block-removal snapshot.
Future<bool> deletePreviousUrlBackedBlock(EditorState editorState) async {
  if (!canDeletePreviousUrlBackedBlock(editorState)) {
    return false;
  }
  final selection = editorState.selection!;
  final currentNode = editorState.getNodeAtPath(selection.start.path)!;
  final previousNode = currentNode.previous!;
  final landingSelection = Selection.single(
    path: previousNode.path,
    startOffset: 0,
  );
  final transaction = editorState.transaction
    ..deleteNode(previousNode)
    ..afterSelection = landingSelection
    ..selectionExtraInfo = {}
    ..customSelectionType = SelectionType.inline;
  if ((previousNode.type == collabDividerType ||
          previousNode.type == collabFormulaType) &&
      editorState.undoManager.undoStack.isNonEmpty) {
    editorState.undoManager.undoStack.last.seal();
  }
  await editorState.apply(
    transaction,
    skipHistoryDebounce:
        previousNode.type == collabDividerType ||
        previousNode.type == collabFormulaType,
  );
  return true;
}

/// 判断 [type] 是否属于可通过后置段落行首退格删除的资源、分割线或公式，无副作用。
bool _isUrlBackedBlock(String type) =>
    type == collabDividerType ||
    type == collabFormulaType ||
    isCollabResourceType(type) ||
    type == csesLinkBlockType ||
    type == ImageBlockKeys.type ||
    type == csesVideoBlockType;

/// Keep Backspace from merging the first callout paragraph across its container edge.
bool isProtectedCalloutBoundary(EditorState editorState) {
  if (editorState.isDisposed || !editorState.editable) return false;
  final selection = editorState.selection;
  if (selection == null ||
      !selection.isCollapsed ||
      selection.start.offset != 0) {
    return false;
  }
  final node = editorState.getNodeAtPath(selection.start.path);
  return node?.delta != null &&
      ((node?.parent?.type == csesCalloutBlockType && node?.previous == null) ||
          node?.previous?.type == csesCalloutBlockType);
}

/// Keep Backspace from jumping over opaque blocks and moving later text before them.
bool isProtectedUnsupportedBlockBoundary(EditorState editorState) {
  if (editorState.isDisposed || !editorState.editable) return false;
  final selection = editorState.selection;
  if (selection == null ||
      !selection.isCollapsed ||
      selection.start.offset != 0) {
    return false;
  }
  final node = editorState.getNodeAtPath(selection.start.path);
  final previous = node?.previousNodeWhere(
    (candidate) =>
        candidate.delta != null || candidate.type == csesUnsupportedBlockType,
  );
  return previous?.type == csesUnsupportedBlockType;
}
