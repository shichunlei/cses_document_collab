import 'collab_host_mention_ui.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'collab_mention_tap_handler.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 正文单字符用户提及，显示头像与原始姓名，不附加@字符。
/// 点击仅通知宿主统一回调，未配置时不响应；预览允许点击，不创建人员资料界面。
/// 借用节点与编辑器，不拥有连接；头像由宿主构建，未注入仅显示姓名，不写正文。
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
  /// [name] 是原始显示名，[userId] 是头像/点击事件的稳定身份，[style] 借用段落字号与格式。
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

  /// 必填用户ID，传给宿主头像构建器，不使用显示名作为身份。
  final String userId;

  /// 必填段落样式，控制字号/格式；默认提及使用蓝色。
  final TextStyle style;

  /// 在借用 [context] 中以一个WidgetSpan展示头像与姓名，并限制窄屏最长宽度。
  @override
  Widget build(BuildContext context) {
    final state = context.read<EditorState>();
    final canTap = CollabRuntime.services.onMentionTap != null;
    final avatar = buildHostMentionAvatarSlot(
      context,
      userId: userId,
      name: name,
      size: style.fontSize ?? 16,
    );
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    return Semantics(
      label: '@用户 $name',
      button: canTap,
      child: ExcludeFocus(
        child: GestureDetector(
          key: ValueKey('collab-inline-mention-$id-$offset'),
          onTap: canTap
              ? () async {
                  await handleCollabMentionTap(context, state, node, offset);
                }
              : null,
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
                  if (avatar != null) ...[avatar, const SizedBox(width: 4)],
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
