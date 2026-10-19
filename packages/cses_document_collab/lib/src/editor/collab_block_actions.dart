import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// 将借用 [editor] 中 [node] 的完整图片/音频/视频链接复制到系统剪贴板。
/// [context] 用于成功提示，须由公共更多菜单在退场并校验身份/权限/快照后调用。
/// 本函数仍按稳定身份重新取当前节点；关闭、只读、已删除或类型变化时不执行。
/// 空链接抛出 [StateError]，平台复制失败沿 Future 交给菜单的诊断与失败提示边界。
/// 不下载资源、修改正文或创建撤销记录；迟到结果仅在当前节点/链接/宿主仍有效时提示。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
/// import 'package:flutter/widgets.dart';
/// // 在公共更多菜单的run回调中调用；编辑器、节点和上下文均借自页面。
/// Future<void> copyMedia(BuildContext context, EditorState editor, Node node) =>
///     copyCollabMediaLink(context, editor, node);
/// ```
Future<void> copyCollabMediaLink(BuildContext context, EditorState editor, Node node) async {
  if (!context.mounted || editor.isDisposed || !editor.editable) return;
  final kind = switch (node.type) {
    'image' => '图片',
    'video' => '视频',
    'audio' => '音频',
    _ => null,
  };
  if (kind == null) return;
  final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
  final current = findCollabActionNode(editor, id);
  if (current == null || current.type != node.type) return;
  // 手机投影中的三个资源类型统一使用url；不改写桌面原生src/url属性。
  final url = current.attributes['url'];
  if (url is! String || url.trim().isEmpty) throw StateError('资源链接为空');
  final services = CollabRuntime.services;
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted &&
      !editor.isDisposed &&
      identical(CollabRuntime.services, services) &&
      identical(findCollabActionNode(editor, id), current) &&
      current.attributes['url'] == url) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$kind链接已复制')));
  }
}

/// Shared card menu; appends an editable paragraph without changing the source.
/// Waits for menu dismissal before restoring the new caret and keyboard. The
/// editor/node and extra callbacks are borrowed. A temporary permission listener
/// is removed when the menu and any selected action finish.
/// 正式文档配置链接绑定时统一提供“复制段落链接”，锁定块仍可复制；
/// 未配置或草稿保持原菜单入口显隐。
/// The heading and decorative icon follow the block type unless callers override them.
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
  /// [menuTitle]/[menuIcon] override the sheet heading and decorative icon independently;
  /// null resolves the corresponding value from [node] type. Unknown types use 内容/file.
  /// These affect only the sheet header; the more button and commands keep their behavior.
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
    this.menuTitle,
    this.menuIcon,
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

  /// Optional heading override; null uses the block type name (unknown types use 内容).
  final String? menuTitle;

  /// Optional decorative icon override; null uses the block type icon, preserving the launcher.
  final IconData? menuIcon;

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
    listenable: Listenable.merge([editor.editableNotifier, CollabBlockLocks.of(editor)]),
    builder: (context, _) {
      final available =
          !editor.isDisposed &&
          (CollabBlockLocks.of(editor)?.userId.isNotEmpty == true ||
              (editor.editable ? const {'page', 'callout'}.contains(node.parent?.type) : readOnlyActions.isNotEmpty));
      final VoidCallback? onPressed = available && enabled ? () => _show(context) : null;
      if (triggerBuilder != null) {
        return ExcludeFocus(child: triggerBuilder!(context, onPressed));
      }
      if (!available) return const SizedBox.shrink();
      return ExcludeFocus(
        child: IconButton(
          key: ValueKey('block-lock-menu-trigger-${CollabBlockLocks.idOf(node)}'),
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
  /// Block locks preserve copy/unlock while suppressing mutation commands; inherited
  /// locks expose their source. Permission transitions invalidate the whole old menu.
  /// Insertion below uses the text-line and downward-return icon to show its destination.
  /// 段落链接按正式文档和稳定块ID构造，复制后不修改正文/历史或恢复输入。
  /// Commands use semantic download, external-link, palette, copy, delete or edit icons.
  /// Resolves the block-specific header, applying the caller's [menuTitle]/[menuIcon] overrides.
  Future<void> _show(BuildContext context) async {
    final locks = CollabBlockLocks.of(editor);
    if (editor.isDisposed ||
        (!editor.editable && readOnlyActions.isEmpty && locks == null) ||
        _pending[editor] == true) {
      return;
    }
    final paragraphLinks = CollabParagraphLinks.of(editor);
    final canCopyParagraphLink = paragraphLinks?.supports(node) == true;
    final wasEditable = editor.editable;
    final blockId = CollabBlockLocks.idOf(node);
    final lock = locks?.state(blockId);
    final protected = lock?.locked == true || lock?.containsLock == true;
    final commands = [
      ...readOnlyActions,
      if (wasEditable) ...actions.where((action) => !protected || action.label.startsWith('复制')),
    ];
    final host = collabBlockActionContext(context);
    final services = CollabRuntime.services;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final type = node.type;
    final heading = _defaultBlockMenuHeader(type);
    final snapshot = jsonEncode(protectSubtree ? node.toJson() : node.attributes);
    String? insertedId;
    int? choice;
    var permissionRevoked = false;

    /// Remembers revocation so restoring permissions cannot revive an old menu.
    void trackPermission() {
      if (editor.editable != wasEditable || locks?.state(blockId) != lock) permissionRevoked = true;
    }

    editor.editableNotifier.addListener(trackPermission);
    locks?.addListener(trackPermission);
    _pending[editor] = true;
    try {
      await runEditorHeaderAction<void>(
        host,
        editor,
        () async {
          choice = await showCollabBottomSheet<int>(
            context: host,
            builder: (sheet) => ListenableBuilder(
              listenable: Listenable.merge([editor.editableNotifier, locks]),
              builder: (sheet, _) => CollabBottomSheet(
                title: Text(menuTitle ?? heading.$1),
                icon: menuIcon ?? heading.$2,
                contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (locks != null && locks.userId.isNotEmpty) ...[
                      SwitchListTile(
                        key: ValueKey('block-lock-$id'),
                        secondary: const Icon(LucideIcons.lockKeyhole),
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
                        onChanged: !permissionRevoked && locks.canToggle(id) ? (_) => Navigator.pop(sheet, -2) : null,
                      ),
                      if (lock?.locked == true && lock?.explicit != true)
                        ListTile(
                          leading: const Icon(LucideIcons.cornerUpLeft),
                          title: const Text('定位上级锁定块'),
                          onTap: () => Navigator.pop(sheet, -3),
                        ),
                      ListTile(
                        key: ValueKey('block-copy-$id'),
                        leading: const Icon(LucideIcons.copy),
                        title: const Text('复制内容'),
                        onTap: () => Navigator.pop(sheet, -4),
                      ),
                    ],
                    if (canCopyParagraphLink)
                      ListTile(
                        key: ValueKey('block-copy-paragraph-link-$id'),
                        leading: const Icon(LucideIcons.link),
                        title: const Text('复制段落链接'),
                        onTap: () => Navigator.pop(sheet, -5),
                      ),
                    if (wasEditable && !protected && const {'page', 'callout'}.contains(node.parent?.type))
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
                          _blockActionIcon(commands[i].label),
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
          if (choice == -5) {
            if (identical(CollabParagraphLinks.of(editor), paragraphLinks)) {
              await paragraphLinks?.copy(host, source, isCurrent: () => !permissionRevoked);
            }
            return;
          }
          if (choice == -2 && locks != null && lock != null) {
            await locks.commit(id, !lock.explicit, lock);
            return;
          }
          if (choice == -3 && lock?.sourceId != null) {
            final ancestor = findCollabActionNode(editor, lock!.sourceId!);
            final target = ancestor?.key.currentContext;
            if (target != null && target.mounted) {
              await Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 250));
            }
            return;
          }
          if (choice == -4) {
            String text(Node value) => [
              value.delta?.toPlainText() ?? value.attributes['url'] as String? ?? '',
              ...value.children.map(text),
            ].where((v) => v.isNotEmpty).join('\n');
            await Clipboard.setData(ClipboardData(text: text(source)));
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
      locks?.removeListener(trackPermission);
      _pending[editor] = null;
    }
  }
}

/// Prevents repeated menus while keeping editor lifetimes externally owned.
final _pending = Expando<bool>('block-more-actions');

/// Resolves borrowed block [type] to the shared menu's default heading and Lucide icon.
/// Explicit caller overrides take precedence; unknown future types use 内容/file rather
/// than implying a recognized type. Callouts use a highlighter and page dividers a
/// horizontal separator. Mermaid shares the chart-network icon with its card and
/// insertion entry; the mapping owns no editor or business resources.
(String, IconData) _defaultBlockMenuHeader(String type) => switch (type) {
  'image' => ('图片', LucideIcons.image),
  'video' => ('视频', LucideIcons.film),
  'code' => ('代码块', LucideIcons.codeXml),
  'callout' => ('高亮块', LucideIcons.highlighter),
  'audio' => ('音频', LucideIcons.audioLines),
  'attachment' => ('附件', LucideIcons.paperclip),
  'formula' => ('公式', LucideIcons.sigma),
  'mermaid' => ('代码绘图', LucideIcons.chartNetwork),
  'link' => ('链接', LucideIcons.link),
  'meeting' => ('会议', LucideIcons.users),
  'task' => ('任务', LucideIcons.listTodo),
  'kr-list' => ('会议 KR', LucideIcons.listTodo),
  'page-divider' => ('分页符', LucideIcons.separatorHorizontal),
  _ => ('内容', LucideIcons.file),
};

/// 根据操作文案[label]返回语义图标；下载优先于打开，避免附件复合操作误用外链图标。
/// 删除、复制、颜色和外部打开分别使用对应Lucide图标，其余编辑命令使用铅笔。
IconData _blockActionIcon(String label) {
  if (label.contains('删除')) return LucideIcons.trash2;
  if (label.contains('复制')) return LucideIcons.copy;
  if (label.contains('下载')) return LucideIcons.download;
  if (label.contains('打开')) return LucideIcons.externalLink;
  if (label.contains('颜色')) return LucideIcons.palette;
  return LucideIcons.pencil;
}
