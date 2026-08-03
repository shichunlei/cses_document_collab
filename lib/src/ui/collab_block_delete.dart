import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Handles a hardware Backspace before AppFlowy's standard command.
///
/// AppFlowy's default collapsed-selection handler searches backward for a node
/// with a Delta. Link, image and video blocks intentionally have no Delta, so
/// the default handler skips over them and can merge with an unrelated earlier
/// paragraph. Giving this command first priority makes Backspace delete the
/// immediately preceding collaborative resource block instead.
final collabUrlBackedBlockBackspaceCommand = CommandShortcutEvent(
  key: 'cses-delete-previous-url-backed-block',
  command: 'backspace, shift+backspace',
  getDescription: () => '删除前一个链接、图片或视频块',
  handler: (editorState) {
    if (isProtectedDocumentTitleBoundary(editorState)) {
      return KeyEventResult.handled;
    }
    if (!canDeletePreviousUrlBackedBlock(editorState)) {
      return KeyEventResult.ignored;
    }
    unawaited(deletePreviousUrlBackedBlock(editorState));
    return KeyEventResult.handled;
  },
);

/// Intercepts Backspace events produced by Android/iOS software keyboards.
///
/// Mobile IME deletions call AppFlowy's text-input interceptor chain directly
/// rather than the hardware command list, so both entry points are required to
/// provide identical behavior.
class CollabUrlBackedBlockDeleteInterceptor
    extends AppFlowyKeyboardServiceInterceptor {
  @override
  Future<bool> interceptDelete(
    TextEditingDeltaDeletion deletion,
    EditorState editorState,
  ) async {
    if (isProtectedDocumentTitleBoundary(editorState)) {
      return true;
    }
    if (!canDeletePreviousUrlBackedBlock(editorState)) {
      return false;
    }
    return deletePreviousUrlBackedBlock(editorState);
  }
}

/// Prevents the first body paragraph from merging into the document title.
///
/// AppFlowy's default Backspace handler merges adjacent Delta nodes at offset
/// zero. The title is deliberately a Delta node so it can use the native IME,
/// but it is also a structural header and must never absorb body content.
bool isProtectedDocumentTitleBoundary(EditorState editorState) {
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

/// Returns whether Backspace at the current caret should remove a resource.
bool canDeletePreviousUrlBackedBlock(EditorState editorState) {
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
    ..afterSelection = landingSelection;
  await editorState.apply(transaction);
  return true;
}

bool _isUrlBackedBlock(String type) =>
    type == csesLinkBlockType ||
    type == ImageBlockKeys.type ||
    type == csesVideoBlockType;
