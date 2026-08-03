import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
import 'package:cses_mobile_collab_demo/src/ui/collaborative_editor_page.dart';
import 'package:flutter/material.dart';

class CollabDemoPage extends StatefulWidget {
  const CollabDemoPage({super.key});

  @override
  State<CollabDemoPage> createState() => _CollabDemoPageState();
}

class _CollabDemoPageState extends State<CollabDemoPage> {
  late final CollabController _collab;
  late final TextEditingController _serverUrl;

  @override
  void initState() {
    super.initState();
    _collab = CollabController();
    _serverUrl = TextEditingController(text: _collab.serverUrl);
    _collab.initialize();
  }

  @override
  void dispose() {
    _serverUrl.dispose();
    _collab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _collab,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('CSES 协同 Demo'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _StatusChip(status: _collab.status),
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ConnectionPanel(
                    urlController: _serverUrl,
                    documentId: _collab.documentId,
                    event: _collab.lastProtocolEvent,
                    persistedUpdateCount: _collab.persistedUpdateCount,
                    blockCount: _collab.blockCount,
                    sharedTypeName: _collab.sharedTypeName,
                    onConnect: () =>
                        _collab.updateServerUrlAndReconnect(_serverUrl.text),
                    onReset: _confirmReset,
                  ),
                  if (_collab.error != null) ...[
                    const SizedBox(height: 12),
                    _ErrorBanner(message: _collab.error!),
                  ],
                  const SizedBox(height: 16),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    elevation: 0,
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'AppFlowy 协同正文',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '支持 paragraph、H1–H6、两种列表、Todo、引用，以及'
                            '加粗、斜体、下划线、删除线和行内代码。每块文本使用 '
                            'Y.Text 原生富文本属性协同，离线更新写入 SQLite。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const Divider(height: 28),
                          FilledButton.icon(
                            key: const ValueKey('open-collaborative-editor'),
                            onPressed: _collab.initialized
                                ? _openCollaborativeEditor
                                : null,
                            icon: const Icon(Icons.edit_document),
                            label: Text(
                              _collab.initialized ? '进入协同编辑' : '正在加载文档',
                            ),
                          ),
                          if (!_collab.initialized)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text('正在从 Rust/Yrs 加载本地文档……'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _openCollaborativeEditor() {
    FocusManager.instance.primaryFocus?.unfocus();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => CollaborativeEditorPage(collab: _collab),
      ),
    );
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除本机 Demo 缓存？'),
        content: const Text('只删除这个客户端的 SQLite Update 日志，不会清理服务器内存中的文档。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _collab.resetLocalCache();
    }
  }
}

class _ConnectionPanel extends StatelessWidget {
  const _ConnectionPanel({
    required this.urlController,
    required this.documentId,
    required this.event,
    required this.persistedUpdateCount,
    required this.blockCount,
    required this.sharedTypeName,
    required this.onConnect,
    required this.onReset,
  });

  final TextEditingController urlController;
  final String documentId;
  final String event;
  final int persistedUpdateCount;
  final int blockCount;
  final String sharedTypeName;
  final VoidCallback onConnect;
  final VoidCallback onReset;

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
            Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 380,
                  child: TextField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      labelText: 'y-websocket base URL',
                      isDense: true,
                    ),
                    onSubmitted: (_) => onConnect(),
                  ),
                ),
                FilledButton.icon(
                  onPressed: onConnect,
                  icon: const Icon(Icons.sync),
                  label: const Text('连接 / 重连'),
                ),
                TextButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清本机缓存'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                Text('room: $documentId'),
                Text('protocol: $event'),
                Text('loaded updates: $persistedUpdateCount'),
                Text('blocks: $blockCount'),
                const Text('editor: AppFlowy block editor'),
                Text('shared type: $sharedTypeName'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ConnectionStatus.starting => ('初始化', Colors.blueGrey),
      ConnectionStatus.connecting => ('连接中', Colors.orange),
      ConnectionStatus.online => ('在线', Colors.green),
      ConnectionStatus.offline => ('离线可编辑', Colors.blueGrey),
      ConnectionStatus.error => ('异常', Colors.red),
    };
    return Chip(
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}
