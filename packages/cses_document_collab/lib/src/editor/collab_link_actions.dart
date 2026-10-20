import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_link_view.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_switch_row.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Prevents duplicate action sheets without extending editor lifetimes.
final _pending = Expando<bool>('link-view-actions');

/// Non-view commands returned only after the action sheet is dismissed.
enum _LinkAction {
  /// Commits the inverse explicit lock state through the borrowed authority.
  toggleLock,

  /// Scrolls to the effective locking ancestor without changing content.
  locateLock,

  /// Copies the original URL without changing the document or its history.
  copyLink,

  /// Copies the containing document and stable block reference without changing content.
  copyParagraphLink,

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
/// null omits that command, as for whole-link paragraph actions. Deletion uses
/// the shared danger color for its icon and label. Callbacks are
/// borrowed and must await their own dialogs, including closing animations.
/// View choices are separated from resource actions by a divider; the header
/// shows the URL on one ellipsized line while actions retain the original URL.
/// 正式文档已配置链接绑定时另提供复制段落链接，保留资源地址复制。
/// Insertion below shares the block menu's text-line and downward-return icon.
/// 网页卡片沿用公共块锁的账号、模板锁及额外授权规则；锁定时仅保留打开、复制和锁操作。
/// 打开中的菜单在锁或编辑权限变化后失效，恢复原状态也不恢复写入权限。
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
  final paragraphLinks = CollabParagraphLinks.of(state);
  final locks = CollabBlockLocks.of(state);
  final lock = locks?.state(id);
  final wasEditable = state.editable;
  final protected = lock?.locked == true || lock?.containsLock == true;
  final canManageLock =
      locks != null &&
      locks.userId.isNotEmpty &&
      const {'bookmark', 'embed', 'figma-embed', 'juejin-embed'}.contains(node.type);
  _pending[state] = true;
  String? insertedId;
  Object? action;
  var permissionRevoked = false;

  /// Records lock/edit changes so restoring the old state cannot revive its menu.
  void trackPermission() {
    if (state.editable != wasEditable || locks?.state(id) != lock) permissionRevoked = true;
  }

  state.editableNotifier.addListener(trackPermission);
  locks?.addListener(trackPermission);
  try {
    await runEditorHeaderAction<void>(
      hostContext,
      state,
      () async {
        action = await showCollabBottomSheet<Object>(
          context: hostContext,
          builder: (sheetContext) => ListenableBuilder(
            listenable: Listenable.merge([state.editableNotifier, locks]),
            builder: (sheetContext, _) => CollabBottomSheet(
              title: const Text('链接操作'),
              subtitle: url,
              icon: LucideIcons.link,
              contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (canManageLock) ...[
                    CollabSwitchRow(
                      key: ValueKey('block-lock-$id'),
                      leading: const Icon(LucideIcons.lockKeyhole),
                      title: const Text('锁定内容块'),
                      subtitle: Text(
                        permissionRevoked
                            ? '锁状态或权限已更新，请重新打开'
                            : lock?.locked == true && lock?.explicit != true
                            ? '由上级内容块锁定'
                            : lock?.template == true
                            ? '模板内容已锁定'
                            : lock?.locked == true && lock?.ownerId != locks.userId
                            ? '由其他用户锁定'
                            : lock?.locked == true
                            ? '解锁后可以编辑'
                            : '锁定后保护此块及全部子块',
                      ),
                      value: lock?.locked ?? false,
                      onChanged: !permissionRevoked && locks.canToggle(id)
                          ? (_) => Navigator.pop(sheetContext, _LinkAction.toggleLock)
                          : null,
                    ),
                    if (lock?.locked == true && lock?.explicit != true)
                      CollabMenuRow(
                        leading: const Icon(LucideIcons.cornerUpLeft),
                        title: const Text('定位上级锁定块'),
                        onTap: () => Navigator.pop(sheetContext, _LinkAction.locateLock),
                      ),
                  ],
                  CollabMenuRow(
                    leading: const Icon(LucideIcons.externalLink),
                    title: const Text('在浏览器打开'),
                    onTap: () async {
                      try {
                        if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
                          throw StateError('无法打开链接');
                        }
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      } catch (error, stack) {
                        services.onError?.call('无法打开链接', error, stack, 'DocCollab');
                        if (sheetContext.mounted) {
                          ScaffoldMessenger.maybeOf(
                            sheetContext,
                          )?.showSnackBar(const SnackBar(content: Text('无法打开此链接')));
                        }
                      }
                    },
                  ),
                  CollabMenuRow(
                    key: const ValueKey('link-copy'),
                    leading: const Icon(LucideIcons.copy),
                    title: const Text('复制链接'),
                    onTap: () => Navigator.pop(sheetContext, _LinkAction.copyLink),
                  ),
                  if (paragraphLinks?.supports(node) == true)
                    CollabMenuRow(
                      key: ValueKey('block-copy-paragraph-link-$id'),
                      leading: const Icon(LucideIcons.link),
                      title: const Text('复制段落链接'),
                      onTap: () => Navigator.pop(sheetContext, _LinkAction.copyParagraphLink),
                    ),
                  if (state.editable && !protected && onEdit != null)
                    CollabMenuRow(
                      key: ValueKey('resource-edit-$id'),
                      leading: const Icon(LucideIcons.pencil),
                      title: const Text('修改'),
                      onTap: () => Navigator.pop(sheetContext, _LinkAction.edit),
                    ),
                  if (state.editable && !protected && onDelete != null)
                    CollabMenuRow(
                      key: ValueKey('resource-delete-$id'),
                      iconColor: CollabModalColors.of(sheetContext).danger,
                      textColor: CollabModalColors.of(sheetContext).danger,
                      leading: const Icon(LucideIcons.trash2),
                      title: const Text('删除链接'),
                      onTap: () => Navigator.pop(sheetContext, _LinkAction.delete),
                    ),
                  if (state.editable && !protected && const {'page', 'callout'}.contains(node.parent?.type))
                    CollabMenuRow(
                      key: const ValueKey('link-insert-below'),
                      leading: const Icon(LucideIcons.listEnd),
                      title: const Text('在下方插入'),
                      onTap: () => Navigator.pop(sheetContext, _LinkAction.insertBelow),
                    ),
                  if (state.editable && !protected && const {'page', 'callout'}.contains(node.parent?.type)) ...[
                    Divider(
                      height: 16,
                      thickness: 1,
                      indent: 12,
                      endIndent: 12,
                      color: CollabModalColors.of(sheetContext).line,
                    ),
                    for (final view in CollabLinkView.values)
                      CollabMenuRow(
                        key: ValueKey('link-view-${view.name}'),
                        selected: view == currentView,
                        title: Text(view.label),
                        trailing: view == currentView ? const Icon(LucideIcons.check) : null,
                        onTap: () => Navigator.pop(sheetContext, view),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );

        if (action == null ||
            action == currentView ||
            !hostContext.mounted ||
            state.isDisposed ||
            !identical(CollabRuntime.services, services)) {
          return;
        }
        final source = findCollabLinkNode(state, id);
        if (source == null || collabLinkFingerprint(source) != fingerprint) {
          ScaffoldMessenger.maybeOf(hostContext)?.showSnackBar(const SnackBar(content: Text('内容已更新，请重新选择')));
          return;
        }
        if (action == _LinkAction.toggleLock || action == _LinkAction.locateLock) {
          if (permissionRevoked || !identical(CollabBlockLocks.of(state), locks)) return;
          if (action == _LinkAction.toggleLock && canManageLock && lock != null && locks.canToggle(id)) {
            await locks.commit(id, !lock.explicit, lock);
          } else if (action == _LinkAction.locateLock && lock?.sourceId != null) {
            final target = findCollabActionNode(state, lock!.sourceId!)?.key.currentContext;
            if (target != null && target.mounted) {
              await Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 250));
            }
          }
          return;
        }
        if (action == _LinkAction.copyParagraphLink) {
          if (!permissionRevoked && identical(CollabParagraphLinks.of(state), paragraphLinks)) {
            await paragraphLinks?.copy(hostContext, source, isCurrent: () => !permissionRevoked);
          }
          return;
        }
        if (action == _LinkAction.copyLink) {
          await Clipboard.setData(ClipboardData(text: url));
          if (hostContext.mounted && !state.isDisposed && identical(CollabRuntime.services, services)) {
            ScaffoldMessenger.maybeOf(hostContext)
              ?..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text('链接已复制')));
          }
          return;
        }
        if (!state.editable || permissionRevoked || protected) return;
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
              : paragraph.attributes['cses_collab_block_id'] as String? ?? paragraph.id;
          return;
        }
        if (action is CollabLinkView &&
            !await changeCollabLinkView(state, source, action as CollabLinkView, fingerprint: fingerprint)) {
          if (hostContext.mounted && state.editable) {
            ScaffoldMessenger.maybeOf(hostContext)?.showSnackBar(const SnackBar(content: Text('内容已更新，请重新选择')));
          }
        }
      },
      canRestore: () =>
          action != _LinkAction.delete &&
          action != _LinkAction.toggleLock &&
          action != _LinkAction.locateLock &&
          !permissionRevoked &&
          identical(CollabRuntime.services, services) &&
          (insertedId == null || findCollabLinkNode(state, insertedId!) != null),
      selectionAfterAction: () {
        final target = insertedId == null ? null : findCollabLinkNode(state, insertedId!);
        return target == null ? null : Selection.single(path: target.path, startOffset: 0);
      },
    );
  } catch (error, stack) {
    services.onError?.call('链接操作失败', error, stack, 'DocCollab');
    if (hostContext.mounted && !state.isDisposed && identical(CollabRuntime.services, services)) {
      ScaffoldMessenger.maybeOf(hostContext)?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  } finally {
    state.editableNotifier.removeListener(trackPermission);
    locks?.removeListener(trackPermission);
    _pending[state] = null;
  }
}

/// Redirects taps on a whole-link [node] to view actions in borrowed [context].
/// [span] must be the mobile decorator's span, whose recognizer stays owned by
/// the rich-text renderer. Mixed paragraphs keep their normal behavior; replacing
/// both tap handlers avoids scheduling the upstream long-press editing timer.
TextSpan decorateCollabLinkSpan(BuildContext context, Node node, TextSpan span) {
  final recognizer = span.recognizer;
  if (node.type == 'paragraph' && collabLinkUrl(node) != null && recognizer is TapGestureRecognizer) {
    recognizer
      ..onTapDown = null
      ..onTapUp = (_) => unawaited(showCollabLinkActions(context, node));
  }
  return span;
}
