import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_link_view.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Prevents duplicate action sheets without extending editor lifetimes.
final _pending = Expando<bool>('link-view-actions');

/// Non-view commands returned only after the action sheet is dismissed.
enum _LinkAction {
  /// Copies the original URL without changing the document or its history.
  copyLink,

  /// Creates an editable paragraph immediately after the current link block.
  insertBelow,

  /// Opens the host-provided resource editor after menu dismissal.
  edit,

  /// Deletes only the current resource block through its host callback.
  delete,
}

/// Presents opening/copy/insertion/view actions for borrowed [node] in [context].
/// The editor and host services remain borrowed; input is suspended until the
/// sheet's closing animation finishes. URL/identity/permission/session changes
/// invalidate document operations. Insertion is undoable and restores the new
/// paragraph caret after dismissal; copying is also allowed in readonly mode.
/// Failures report to the original host and surface a local message; this future
/// completes after dismissal and any transaction. Optional [onEdit]/[onDelete]
/// receive the revalidated current node after dismissal and only while editable;
/// null omits that command, as for whole-link paragraph actions. Callbacks are
/// borrowed and must await their own dialogs, including closing animations.
Future<void> showCollabLinkActions(
  BuildContext context,
  Node node, {
  Future<void> Function(Node source)? onEdit,
  Future<void> Function(Node source)? onDelete,
}) async {
  final state = context.read<EditorState>();
  final hostContext = collabBlockActionContext(context);
  final url = collabLinkUrl(node);
  if (url == null || state.isDisposed || _pending[state] == true) return;
  final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
  final fingerprint = collabLinkFingerprint(node);
  final currentView = collabLinkView(node);
  final services = CollabRuntime.services;
  _pending[state] = true;
  String? insertedId;
  Object? action;
  var permissionRevoked = false;

  /// Keeps revoked permissions from reviving mutations in an old menu.
  void trackPermission() {
    if (!state.editable) permissionRevoked = true;
  }

  state.editableNotifier.addListener(trackPermission);
  try {
    await runEditorHeaderAction<void>(
      hostContext,
      state,
      () async {
        final route = ModalBottomSheetRoute<Object>(
          isScrollControlled: true,
          builder: (sheetContext) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text(
                      url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.open_in_new),
                    title: const Text('在浏览器打开'),
                    onTap: () async {
                      try {
                        if (!await launchUrl(
                          Uri.parse(url),
                          mode: LaunchMode.externalApplication,
                        )) {
                          throw StateError('无法打开链接');
                        }
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      } catch (error, stack) {
                        services.onError?.call(
                          '无法打开链接',
                          error,
                          stack,
                          'DocCollab',
                        );
                        if (sheetContext.mounted) {
                          ScaffoldMessenger.maybeOf(sheetContext)?.showSnackBar(
                            const SnackBar(content: Text('无法打开此链接')),
                          );
                        }
                      }
                    },
                  ),
                  ListTile(
                    key: const ValueKey('link-copy'),
                    leading: const Icon(Icons.copy_outlined),
                    title: const Text('复制链接'),
                    onTap: () =>
                        Navigator.pop(sheetContext, _LinkAction.copyLink),
                  ),
                  if (state.editable && onEdit != null)
                    ListTile(
                      key: ValueKey('resource-edit-$id'),
                      leading: const Icon(Icons.edit_outlined),
                      title: const Text('修改'),
                      onTap: () =>
                          Navigator.pop(sheetContext, _LinkAction.edit),
                    ),
                  if (state.editable && onDelete != null)
                    ListTile(
                      key: ValueKey('resource-delete-$id'),
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('删除卡片'),
                      onTap: () =>
                          Navigator.pop(sheetContext, _LinkAction.delete),
                    ),
                  if (state.editable &&
                      const {'page', 'callout'}.contains(node.parent?.type))
                    ListTile(
                      key: const ValueKey('link-insert-below'),
                      leading: const Icon(Icons.add),
                      title: const Text('在下方插入'),
                      onTap: () =>
                          Navigator.pop(sheetContext, _LinkAction.insertBelow),
                    ),
                  if (state.editable &&
                      const {'page', 'callout'}.contains(node.parent?.type))
                    for (final view in CollabLinkView.values)
                      ListTile(
                        key: ValueKey('link-view-${view.name}'),
                        title: Text(view.label),
                        trailing: view == currentView
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () => Navigator.pop(sheetContext, view),
                      ),
                ],
              ),
            ),
          ),
        );
        action = await Navigator.of(hostContext).push(route);
        await route.completed;
        if (action == null ||
            action == currentView ||
            !hostContext.mounted ||
            state.isDisposed ||
            !identical(CollabRuntime.services, services)) {
          return;
        }
        final source = findCollabLinkNode(state, id);
        if (source == null || collabLinkFingerprint(source) != fingerprint) {
          ScaffoldMessenger.maybeOf(
            hostContext,
          )?.showSnackBar(const SnackBar(content: Text('内容已更新，请重新选择')));
          return;
        }
        if (action == _LinkAction.copyLink) {
          await Clipboard.setData(ClipboardData(text: url));
          if (hostContext.mounted &&
              !state.isDisposed &&
              identical(CollabRuntime.services, services)) {
            ScaffoldMessenger.maybeOf(hostContext)
              ?..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text('链接已复制')));
          }
          return;
        }
        if (!state.editable || permissionRevoked) return;
        if (action == _LinkAction.edit) {
          await onEdit?.call(source);
          return;
        }
        if (action == _LinkAction.delete) {
          await onDelete?.call(source);
          return;
        }
        if (action == _LinkAction.insertBelow) {
          if (!const {'page', 'callout'}.contains(source.parent?.type)) return;
          final paragraph = await insertCollabParagraphBelow(state, source);
          insertedId = paragraph == null
              ? null
              : paragraph.attributes['cses_collab_block_id'] as String? ??
                    paragraph.id;
          return;
        }
        if (action is CollabLinkView &&
            !await changeCollabLinkView(
              state,
              source,
              action as CollabLinkView,
              fingerprint: fingerprint,
            )) {
          if (hostContext.mounted && state.editable) {
            ScaffoldMessenger.maybeOf(
              hostContext,
            )?.showSnackBar(const SnackBar(content: Text('内容已更新，请重新选择')));
          }
        }
      },
      canRestore: () =>
          action != _LinkAction.delete &&
          !permissionRevoked &&
          identical(CollabRuntime.services, services) &&
          (insertedId == null ||
              findCollabLinkNode(state, insertedId!) != null),
      selectionAfterAction: () {
        final target = insertedId == null
            ? null
            : findCollabLinkNode(state, insertedId!);
        return target == null
            ? null
            : Selection.single(path: target.path, startOffset: 0);
      },
    );
  } catch (error, stack) {
    services.onError?.call('链接操作失败', error, stack, 'DocCollab');
    if (hostContext.mounted &&
        !state.isDisposed &&
        identical(CollabRuntime.services, services)) {
      ScaffoldMessenger.maybeOf(
        hostContext,
      )?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  } finally {
    state.editableNotifier.removeListener(trackPermission);
    _pending[state] = null;
  }
}

/// Redirects taps on a whole-link [node] to view actions in borrowed [context].
/// [span] must be the mobile decorator's span, whose recognizer stays owned by
/// the rich-text renderer. Mixed paragraphs keep their normal behavior; replacing
/// both tap handlers avoids scheduling the upstream long-press editing timer.
TextSpan decorateCollabLinkSpan(
  BuildContext context,
  Node node,
  TextSpan span,
) {
  final recognizer = span.recognizer;
  if (node.type == 'paragraph' &&
      collabLinkUrl(node) != null &&
      recognizer is TapGestureRecognizer) {
    recognizer
      ..onTapDown = null
      ..onTapUp = (_) => unawaited(showCollabLinkActions(context, node));
  }
  return span;
}
