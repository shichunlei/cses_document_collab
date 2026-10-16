import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:flutter/material.dart';

/// 已登录文档的状态面板；展示名读取 Common 当前用户，不接受手填身份或连接配置。
class CsesConnectionPanel extends StatelessWidget {
  /// [collab] 由宿主持有，[onReset] 确认后清理本机正文缓存。
  const CsesConnectionPanel({super.key, required this.collab, required this.onReset, required this.onReconnect});

  final CollabController collab;
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
            Text('测试文档', style: Theme.of(context).textTheme.titleMedium),
            if (collab.config.isFormal) ...[const SizedBox(height: 8), Text('当前账号：${User().userName}')],
            const SizedBox(height: 8),
            const SelectableText(csesDemoDocumentId),
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
