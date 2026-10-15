import 'collab_mention_avatar.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

/// 正文单字符用户提及，显示头像与原始姓名，不附加@字符。
/// 点击打开人员资料/复制/删除，预览允许查看但不能改正文。
/// 借用节点与编辑器，不拥有连接；头像按稳定用户ID加载公共图片，失败回退姓名首字，不写正文。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_inline_mention.dart';
/// final mention = CollabInlineMention(node: paragraphNode(), offset: 0,
///   name: '张三', userId: 'u1', style: const TextStyle(fontSize: 16));
/// // 放入提供EditorState的WidgetSpan中。
/// ```
class CollabInlineMention extends StatelessWidget {
  /// [key] 控制身份与状态复用，[node] 是借用节点，[offset] 为UTF-16对象位置，
  /// [name] 是原始显示名，[userId] 是头像/资料的稳定身份，[style] 借用段落字号与格式。
  const CollabInlineMention({
    super.key,
    required this.node,
    required this.offset,
    required this.name,
    required this.userId,
    required this.style,
  });

  /// 编辑器拥有的文字节点，必填，不释放。
  final Node node;

  /// 必填UTF-16对象位置，点击时重新捕获身份。
  final int offset;

  /// 必填显示名，不自动写回用户最新名称。
  final String name;

  /// 必填用户ID，头像按此身份拼接，不使用显示名作为资源路径。
  final String userId;

  /// 必填段落样式，控制字号/格式；默认提及使用蓝色。
  final TextStyle style;

  /// 在借用 [context] 中以一个WidgetSpan展示头像与姓名，并限制窄屏最长宽度。
  @override
  Widget build(BuildContext context) {
    final state = context.read<EditorState>();
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    return Semantics(
      label: '@用户 $name',
      button: true,
      child: ExcludeFocus(
        child: GestureDetector(
          key: ValueKey('collab-inline-mention-$id-$offset'),
          onTap: () async {
            final target = CollabUserMentionTarget.capture(node, offset);
            if (target == null) return;
            try {
              await runEditorHeaderAction<void>(
                context,
                state,
                () => _showProfile(context, state, target),
              );
            } catch (error, stack) {
              CollabDiagnostics.report(
                '用户提及操作失败',
                error: error,
                stackTrace: stack,
                tag: 'DocCollab',
              );
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(
                  context,
                )?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
              }
            }
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (MediaQuery.sizeOf(context).width - 40).clamp(
                40,
                double.infinity,
              ),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CollabMentionAvatar(
                    userId: userId,
                    name: name,
                    size: style.fontSize ?? 16,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.copyWith(
                        color: style.color ?? const Color(0xFF2563EB),
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 在借用 [context]/[state] 中展示稳定 [target] 的人员资料，退场完成后才恢复正文。
/// 删除前核对权限和原身份；远端变化不覆盖，加载资料失败仍显示正文姓名/ID。
Future<void> _showProfile(
  BuildContext context,
  EditorState state,
  CollabUserMentionTarget target,
) async {
  final profile = CollabRuntime.services.mentionDirectory?.load(target.userId);
  ModalRoute<void>? route;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      route = ModalRoute.of(context);
      return FutureBuilder<CollabMentionUser?>(
        future: profile,
        builder: (context, snapshot) {
          final user = snapshot.data;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      CollabMentionAvatar(
                        userId: target.userId,
                        name: user?.name ?? target.name,
                        avatarUrl: user?.avatarUrl,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          user?.name ?? target.name,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  SelectableText('用户ID：${target.userId}'),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const LinearProgressIndicator(),
                  if (snapshot.hasError) const Text('资料加载失败，显示文档中的姓名'),
                  if (user?.department != null) Text('部门：${user!.department}'),
                  if (user?.position != null) Text('职位：${user!.position}'),
                  TextButton(
                    key: const ValueKey('mention-copy-id'),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: target.userId),
                      );
                    },
                    child: const Text('复制用户ID'),
                  ),
                  TextButton(
                    key: const ValueKey('mention-copy-name'),
                    onPressed: () async {
                      await _copy(context, target.name);
                    },
                    child: const Text('复制姓名'),
                  ),
                  ListenableBuilder(
                    listenable: state.editableNotifier,
                    builder: (context, _) => TextButton(
                      key: const ValueKey('mention-delete'),
                      onPressed: !state.isDisposed && state.editable
                          ? () async {
                              await _delete(context, state, target);
                            }
                          : null,
                      child: const Text('删除提及'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  await route?.completed;
}

/// 将[text]复制到平台剪贴板；借用[context]显示失败，异常交宿主报告，不写正文。
Future<void> _copy(BuildContext context, String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } catch (error, stack) {
    CollabDiagnostics.report(
      '复制用户信息失败',
      error: error,
      stackTrace: stack,
      tag: 'DocCollab',
    );
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
    }
  }
}

/// 在借用[context]/[state]中删除稳定[target]；完成后关闭面板，失败留在面板并提示。
Future<void> _delete(
  BuildContext context,
  EditorState state,
  CollabUserMentionTarget target,
) async {
  try {
    final deleted = await deleteCollabUserMention(state, target);
    if (!context.mounted) return;
    if (deleted) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('提及已变化，请关闭后重新打开')));
    }
  } catch (error, stack) {
    CollabDiagnostics.report(
      '删除用户提及失败',
      error: error,
      stackTrace: stack,
      tag: 'DocCollab',
    );
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
    }
  }
}
