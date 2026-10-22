import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';

/// 已登录文档的状态面板；展示名读取 Common 当前用户，不接受手填身份或连接配置。
///
/// ```dart
/// import 'package:flutter/widgets.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/cses_connection_panel.dart';
/// Widget statusPanel(CollabController collab) => CsesConnectionPanel(
///   collab: collab, onReset: collab.resetLocalCache, onReconnect: collab.retry);
/// ```
class CsesConnectionPanel extends StatelessWidget {
  /// [key]控制组件身份，[collab]由宿主持有，[onReset]确认后清理本机正文缓存，
  /// [onReconnect]由宿主恢复主连接后发起文档重同步。
  const CsesConnectionPanel({super.key, required this.collab, required this.onReset, required this.onReconnect});

  /// 借用当前正式或草稿控制器，不释放它；显示其真实文档ID。
  final CollabController collab;

  /// 用户确认后的缓存清理操作，由宿主决定是否允许执行。
  final Future<void> Function() onReset;

  /// Host-owned connection recovery followed by document sync.
  final Future<void> Function() onReconnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('当前文档', style: Theme.of(context).textTheme.titleMedium),
            if (collab.config.isFormal) ...[const SizedBox(height: 8), Text('当前账号：${User().userName}')],
            const SizedBox(height: 8),
            SelectableText(collab.documentId),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: collab.config.isFormal && collab.initialized && !collab.busy ? onReconnect : null,
                  icon: const Icon(Icons.sync),
                  label: const Text('重新连接'),
                ),
                TextButton.icon(
                  onPressed: collab.initialized && !collab.busy ? onReset : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清本机缓存'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (collab.readOnlyReason != null) ...[Text('只读：${collab.readOnlyReason}'), const SizedBox(height: 8)],
            Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                Text('protocol: ${collab.lastProtocolEvent}'),
                Text('loaded updates: ${collab.persistedUpdateCount}'),
                Text('blocks: ${collab.blockCount}'),
                Text('其他编辑器: ${collab.remoteEditorCount}'),
                Text('shared type: ${collab.sharedTypeName}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
