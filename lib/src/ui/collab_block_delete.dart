import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_common/observability/api/log.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_list_editing.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 硬件 Backspace/Shift+Backspace 的协同入口，置于标准命令前。
/// 行首列表先退级，随后保护标题边界，再处理前置资源删除；不接管行内文字和范围删除。
/// 编辑器命令回调必须同步返回 KeyEventResult，事务由私有异步异常边界等待并上报失败。
/// 借用 EditorState，无额外监听或资源；软键盘通过同规则的拦截器处理。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_mobile_collab_demo/src/ui/collab_block_delete.dart';
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
    if (isProtectedDocumentTitleBoundary(state)) {
      return KeyEventResult.handled;
    }
    if (!canDeletePreviousUrlBackedBlock(state)) {
      return KeyEventResult.ignored;
    }
    unawaited(_runBackspaceTransaction(state, outdent: false));
    return KeyEventResult.handled;
  },
);

/// 移动 IME 删除拦截器，统一列表退级、标题保护和相邻媒体删除的优先级。
/// AppFlowy 在调用前移除行首占位符；退格占位符表现为逻辑位置 0 的折叠删除范围。
/// 非折叠删除和正在组合的候选文字交给原输入链，避免把实际删字误判成退级。
/// 不拥有编辑器或键盘服务；创建方在服务挂载后注册，换 EditorState/退出时注销。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_mobile_collab_demo/src/ui/collab_block_delete.dart';
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
  /// 非列表沿用标题保护与媒体删除。只读/销毁时不执行；异常通过 Future 交给 IME 边界。
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
    if (isProtectedDocumentTitleBoundary(editorState)) {
      return true;
    }
    if (!canDeletePreviousUrlBackedBlock(editorState)) {
      return false;
    }
    return deletePreviousUrlBackedBlock(editorState);
  }
}

/// 在同步硬件命令边界等待借用 [state] 的事务；[outdent] 为 true 时退级列表，否则删除前置资源。
/// 不持有资源或跨回调保存选区。非预期异常保留原异常与堆栈，统一 Log.e 并交 FlutterError，
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
    Log.e(
      '文档退格事务失败',
      error: error,
      stackTrace: stackTrace,
      tag: 'DocCollabDemo',
    );
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'DocCollabDemo',
        context: ErrorDescription('handling collaborative Backspace'),
      ),
    );
  }
}

/// Prevents the first body paragraph from merging into the document title.
///
/// [editorState] 为借用的编辑器；只读或销毁时返回 false，不修改节点或历史。
/// AppFlowy's default Backspace handler merges adjacent Delta nodes at offset
/// zero. The title is deliberately a Delta node so it can use the native IME,
/// but it is also a structural header and must never absorb body content.
bool isProtectedDocumentTitleBoundary(EditorState editorState) {
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
  return currentNode?.delta != null &&
      currentNode?.previous?.type == csesDocumentTitleBlockType;
}

/// 返回借用的 [editorState] 当前折叠光标是否应删除前置资源；要求偏移 0，且存在前置媒体。
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
/// [editorState] 为借用的编辑器；仅在前置资源可删除时执行。完成事务返回 true，
/// 不满足条件返回 false；异常通过 Future 传播，资源的组件生命周期由编辑器负责。
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
  await editorState.apply(transaction);
  return true;
}

/// 判断 [type] 是否属于既有链接/图片/视频块类型，无副作用。
bool _isUrlBackedBlock(String type) =>
    type == csesLinkBlockType ||
    type == ImageBlockKeys.type ||
    type == csesVideoBlockType;
