import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
/// Callers can supply a business-specific menu heading and decorative icon.
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
/// import 'package:lucide_icons_flutter/lucide_icons.dart';
/// // Borrow the editor and node from the surrounding document component.
/// CollabBlockMoreButton more(EditorState editor, Node node) =>
///     CollabBlockMoreButton(editor: editor, node: node,
///       menuTitle: '会议操作', menuIcon: LucideIcons.users);
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
  /// [menuTitle] defaults to 块操作; [menuIcon] defaults to the Lucide ellipsis.
  /// Both customize the sheet header without changing the more button or commands.
  /// [triggerBuilder] optionally replaces the ellipsis with a custom launch surface;
  /// it receives a null callback when unavailable, including preview without readonly actions.
  const CollabBlockMoreButton({
    super.key,
    required this.editor,
    required this.node,
    this.enabled = true,
    this.actions = const [],
    this.readOnlyActions = const [],
    this.protectSubtree = false,
    this.menuTitle = '块操作',
    this.menuIcon = LucideIcons.ellipsis,
    this.triggerBuilder,
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
  final List<({String label, Key? key, Future<void> Function() run})> readOnlyActions;

  /// Whether child content changes invalidate the open menu; defaults to false.
  final bool protectSubtree;

  /// Sheet heading shown above commands; defaults to 块操作 and is supplied by the caller.
  final String menuTitle;

  /// Decorative sheet icon; defaults to the Lucide ellipsis, without changing the launcher icon.
  final IconData menuIcon;

  /// Optional custom launcher; null keeps the ellipsis button. The builder receives
  /// borrowed context and a nullable activation callback, and must render its own
  /// disabled/readonly surface when the callback is null. The common menu retains
  /// permission, identity, failure and reentry protection; it owns no custom resources.
  final Widget Function(BuildContext context, VoidCallback? onPressed)? triggerBuilder;

  /// Builds the launcher in borrowed [context], reacting to current permissions.
  /// Custom launchers stay visible with a null callback when unavailable; the
  /// default ellipsis remains hidden in preview without readonly actions.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: editor.editableNotifier,
    builder: (context, _) {
      final available =
          !editor.isDisposed &&
          (editor.editable ? const {'page', 'callout'}.contains(node.parent?.type) : readOnlyActions.isNotEmpty);
      final VoidCallback? onPressed = available && enabled ? () => _show(context) : null;
      if (triggerBuilder != null) {
        return ExcludeFocus(child: triggerBuilder!(context, onPressed));
      }
      if (!available) return const SizedBox.shrink();
      return ExcludeFocus(
        child: IconButton(
          tooltip: '更多操作',
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
          padding: EdgeInsets.zero,
          icon: const Icon(LucideIcons.ellipsis, size: 18),
          onPressed: onPressed,
        ),
      );
    },
  );

  /// Opens one sheet in borrowed [context], rejects stale targets and catches failures.
  /// Insertion below uses the text-line and downward-return icon to show its destination.
  /// Uses the caller's [menuTitle] and [menuIcon] in the shared sheet header.
  Future<void> _show(BuildContext context) async {
    if (editor.isDisposed || (!editor.editable && readOnlyActions.isEmpty) || _pending[editor] == true) {
      return;
    }
    final wasEditable = editor.editable;
    final commands = [...readOnlyActions, if (wasEditable) ...actions];
    final host = collabBlockActionContext(context);
    final services = CollabRuntime.services;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final type = node.type;
    final snapshot = jsonEncode(protectSubtree ? node.toJson() : node.attributes);
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
          choice = await showCollabBottomSheet<int>(
            context: host,
            builder: (sheet) => CollabBottomSheet(
              title: Text(menuTitle),
              icon: menuIcon,
              contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (wasEditable)
                    ListTile(
                      key: ValueKey('block-insert-below-$id'),
                      leading: const Icon(LucideIcons.listEnd),
                      title: const Text('在下方插入'),
                      onTap: () => Navigator.pop(sheet, -1),
                    ),
                  for (var i = 0; i < commands.length; i++)
                    ListTile(
                      key: commands[i].key,
                      leading: Icon(
                        commands[i].label.contains('删除')
                            ? LucideIcons.trash2
                            : commands[i].label.contains('复制')
                            ? LucideIcons.copy
                            : LucideIcons.pencil,
                        color: commands[i].label.contains('删除') ? CollabModalColors.of(sheet).danger : null,
                      ),
                      title: Text(
                        commands[i].label,
                        style: commands[i].label.contains('删除')
                            ? TextStyle(color: CollabModalColors.of(sheet).danger)
                            : null,
                      ),
                      onTap: () => Navigator.pop(sheet, i),
                    ),
                ],
              ),
            ),
          );

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
              jsonEncode(protectSubtree ? source.toJson() : source.attributes) != snapshot) {
            ScaffoldMessenger.maybeOf(host)?.showSnackBar(const SnackBar(content: Text('内容已更新，请重新选择')));
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
      if (host.mounted && !editor.isDisposed && identical(CollabRuntime.services, services)) {
        ScaffoldMessenger.maybeOf(host)?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
      }
    } finally {
      editor.editableNotifier.removeListener(trackPermission);
      _pending[editor] = null;
    }
  }
}

/// Prevents repeated menus while keeping editor lifetimes externally owned.
final _pending = Expando<bool>('block-more-actions');
