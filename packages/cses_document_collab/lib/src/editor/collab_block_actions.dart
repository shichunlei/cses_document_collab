import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';

/// Resolves stable [id] in borrowed [editor]; disposed/deleted targets return null.
Node? findCollabActionNode(EditorState editor, String id) {
  if (editor.isDisposed) return null;
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id) return node;
    for (final child in node.children) {
      final result = visit(child);
      if (result != null) return result;
    }
    return null;
  }

  return visit(editor.document.root);
}

/// Returns an editor ancestor of borrowed [context] that survives block reorders.
/// Falls back to [context] when called outside an AppFlowy editor.
BuildContext collabBlockActionContext(BuildContext context) {
  var host = context;
  context.visitAncestorElements((element) {
    if (element.widget is AppFlowyEditor) {
      host = element;
      return false;
    }
    return true;
  });
  return host;
}

/// Inserts an empty sibling after borrowed [source] in [editor], as one undo step.
/// Returns the inserted node or null for readonly, disposed, detached or unsupported
/// parents. Root/callout children are supported, including whole containers.
/// Selection stays suspended; the caller restores input after its menu dismisses.
/// Errors propagate through the apply future; neither borrowed argument is owned.
Future<Node?> insertCollabParagraphBelow(EditorState editor, Node source) async {
  if (editor.isDisposed || !editor.editable || !const {'page', 'callout'}.contains(source.parent?.type)) {
    return null;
  }
  final id = source.attributes['cses_collab_block_id'] as String? ?? source.id;
  if (!identical(findCollabActionNode(editor, id), source)) return null;
  final paragraph = paragraphNode();
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  final transaction = editor.transaction
    ..insertNode(source.path.next, paragraph, deepCopy: false)
    ..afterSelection = null;
  await editor.apply(transaction, skipHistoryDebounce: true);
  return paragraph;
}

/// Shared card menu; appends an editable paragraph without changing the source.
/// Waits for menu dismissal before restoring the new caret and keyboard. The
/// editor/node and extra callbacks are borrowed. A temporary permission listener
/// is removed when the menu and any selected action finish.
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
/// // Borrow the editor and node from the surrounding document component.
/// CollabBlockMoreButton more(EditorState editor, Node node) =>
///     CollabBlockMoreButton(editor: editor, node: node);
/// ```
class CollabBlockMoreButton extends StatelessWidget {
  /// [key] controls widget identity; [editor]/[node] identify the borrowed block.
  /// [enabled] defaults to true; unsupported editing parents hide the menu.
  /// Preview shows only [readOnlyActions], if supplied.
  /// [actions] supplies additional labeled commands with optional test/semantic keys;
  /// callbacks run after dismissal and keep their own mutation/failure contracts.
  /// [readOnlyActions] supplies non-mutating commands shown in both editing and
  /// preview; empty by default. Permission changes invalidate an open menu.
  /// [protectSubtree] also rejects child content changes while the menu is open;
  /// defaults to false for leaf cards and is useful for whole-container deletion.
  const CollabBlockMoreButton({
    super.key,
    required this.editor,
    required this.node,
    this.enabled = true,
    this.actions = const [],
    this.readOnlyActions = const [],
    this.protectSubtree = false,
  });

  /// Required editor, owned by the surrounding document page.
  final EditorState editor;

  /// Required source node; mutations resolve its current stable identity.
  final Node node;

  /// Temporarily disables the button while its source is busy; defaults to true.
  final bool enabled;

  /// Extra commands displayed after insertion; empty by default, callbacks borrowed.
  final List<({String label, Key? key, Future<void> Function() run})> actions;

  /// Borrowed non-mutating commands available in editing and preview; empty by default.
  final List<({String label, Key? key, Future<void> Function() run})>
  readOnlyActions;

  /// Whether child content changes invalidate the open menu; defaults to false.
  final bool protectSubtree;

  /// Builds the more button in borrowed [context]; live permissions govern visibility.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor.editableNotifier,
    builder: (context, _) =>
        editor.isDisposed ||
            (editor.editable
                ? !const {'page', 'callout'}.contains(node.parent?.type)
                : readOnlyActions.isEmpty)
        ? const SizedBox.shrink()
        : ExcludeFocus(
            child: IconButton(
              tooltip: '更多操作',
              style: const ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_horiz, size: 18),
              onPressed: enabled ? () => _show(context) : null,
            ),
          ),
  );

  /// Opens one sheet in borrowed [context], rejects stale targets and catches failures.
  Future<void> _show(BuildContext context) async {
    if (editor.isDisposed ||
        (!editor.editable && readOnlyActions.isEmpty) ||
        _pending[editor] == true) {
      return;
    }
    final wasEditable = editor.editable;
    final commands = [...readOnlyActions, if (wasEditable) ...actions];
    final host = collabBlockActionContext(context);
    final services = CollabRuntime.services;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final type = node.type;
    final snapshot = jsonEncode(
      protectSubtree ? node.toJson() : node.attributes,
    );
    String? insertedId;
    int? choice;
    var permissionRevoked = false;

    /// Remembers revocation so restoring permissions cannot revive an old menu.
    void trackPermission() {
      if (editor.editable != wasEditable) permissionRevoked = true;
    }

    editor.editableNotifier.addListener(trackPermission);
    _pending[editor] = true;
    try {
      await runEditorHeaderAction<void>(
        host,
        editor,
        () async {
          final route = ModalBottomSheetRoute<int>(
            isScrollControlled: true,
            builder: (sheet) => SafeArea(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (wasEditable)
                      ListTile(
                        key: ValueKey('block-insert-below-$id'),
                        leading: const Icon(Icons.add),
                        title: const Text('在下方插入'),
                        onTap: () => Navigator.pop(sheet, -1),
                      ),
                    for (var i = 0; i < commands.length; i++)
                      ListTile(
                        key: commands[i].key,
                        title: Text(commands[i].label),
                        onTap: () => Navigator.pop(sheet, i),
                      ),
                  ],
                ),
              ),
            ),
          );
          choice = await Navigator.of(host).push(route);
          await route.completed;
          if (choice == null ||
              permissionRevoked ||
              !host.mounted ||
              editor.isDisposed ||
              editor.editable != wasEditable ||
              !identical(CollabRuntime.services, services)) {
            return;
          }
          final source = findCollabActionNode(editor, id);
          if (source == null ||
              source.type != type ||
              jsonEncode(
                    protectSubtree ? source.toJson() : source.attributes,
                  ) !=
                  snapshot) {
            ScaffoldMessenger.maybeOf(
              host,
            )?.showSnackBar(const SnackBar(content: Text('内容已更新，请重新选择')));
            return;
          }
          if (choice! >= 0) {
            await commands[choice!].run();
            return;
          }
          final paragraph = await insertCollabParagraphBelow(editor, source);
          insertedId = paragraph == null
              ? null
              : paragraph.attributes['cses_collab_block_id'] as String? ?? paragraph.id;
        },
        canRestore: () =>
            !permissionRevoked &&
            (choice == null || choice == -1) &&
            identical(CollabRuntime.services, services) &&
            (insertedId == null || findCollabActionNode(editor, insertedId!) != null),
        selectionAfterAction: () {
          final target = insertedId == null ? null : findCollabActionNode(editor, insertedId!);
          return target == null ? null : Selection.single(path: target.path, startOffset: 0);
        },
      );
    } catch (error, stack) {
      services.report('块操作失败', error, stack, 'DocCollab');
      if (host.mounted &&
          !editor.isDisposed &&
          identical(CollabRuntime.services, services)) {
        ScaffoldMessenger.maybeOf(
          host,
        )?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
      }
    } finally {
      editor.editableNotifier.removeListener(trackPermission);
      _pending[editor] = null;
    }
  }
}

/// Prevents repeated menus while keeping editor lifetimes externally owned.
final _pending = Expando<bool>('block-more-actions');
