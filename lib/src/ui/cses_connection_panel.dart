import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_account_login.dart';
import 'package:flutter/material.dart';

/// 已登录文档的状态面板；身份来自登录响应，不接受手填 userId、cookie 或设备 ID。
class CsesConnectionPanel extends StatelessWidget {
  /// [collab] 由宿主持有，[session] 是当前认证会话，[onReset] 确认后清理本机正文缓存。
  const CsesConnectionPanel({
    super.key,
    required this.collab,
    this.session,
    required this.onReset,
  });
  final CollabController collab;
  final CsesAccountSession? session;
  final Future<void> Function() onReset;

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
            if (session != null) ...[
              const SizedBox(height: 8),
              Text(
                '当前账号：${session!.displayName.isEmpty ? '已登录' : session!.displayName}',
              ),
            ],
            const SizedBox(height: 8),
            const SelectableText(csesDemoDocumentId),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed:
                      session != null && collab.initialized && !collab.busy
                      ? () => collab.configureCses(session!.settings)
                      : null,
                  icon: const Icon(Icons.sync),
                  label: const Text('重新连接'),
                ),
                TextButton.icon(
                  onPressed: collab.initialized && !collab.busy
                      ? onReset
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清本机缓存'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (collab.readOnlyReason != null) ...[
              Text('只读：${collab.readOnlyReason}'),
              const SizedBox(height: 8),
            ],
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
