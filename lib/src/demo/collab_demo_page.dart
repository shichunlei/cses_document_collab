import 'dart:async';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_connection_panel.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_host.dart';
import 'package:flutter/material.dart';

import 'markdown_file_picker.dart';

/// 登录后的文档入口，拥有编辑器控制器并装配 CSES 状态面板。
class CollabDemoPage extends StatefulWidget {
  /// 创建文档状态页；控制器随此页生命周期创建与释放。
  const CollabDemoPage({super.key, this.localDraft = false, this.onLogout});

  /// 离线预览和测试可显式打开本地草稿；正式文档直接使用 Common 上下文。
  final bool localDraft;

  /// 返回登录页；移除本页会释放协同控制器及共享连接。
  final VoidCallback? onLogout;

  @override
  /// 创建本页资源所有者。
  createState() => _CollabDemoPageState();
}

/// 持有唯一协同控制器，进入正文页时借用同一实例。
class _CollabDemoPageState extends State<CollabDemoPage> {
  late final DemoDocumentHost _host;

  /// Controller borrowed from the demo composition root.
  CollabController get _collab => _host.controller!;

  @override
  /// 初始化本地文档，随后使用登录会话自动连接。
  void initState() {
    super.initState();
    _host = DemoDocumentHost(localDraft: widget.localDraft);
    unawaited(_host.initialize());
  }

  @override
  /// 释放本页创建的编辑器控制器及协同会话。
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  @override
  /// 使用 [context] 渲染当前状态，无网络或缓存副作用。
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _host,
      builder: (context, _) {
        if (_host.controller == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('CSES 协同 Demo')),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(_host.error ?? '正在加载文档…'),
                  const FilledButton(
                    onPressed: null,
                    key: ValueKey('open-collaborative-editor'),
                    child: Text('正在加载文档'),
                  ),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('CSES 协同 Demo'),
            actions: [
              if (widget.onLogout != null)
                IconButton(onPressed: _collab.busy ? null : _logout, tooltip: '退出登录', icon: const Icon(Icons.logout)),
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
                  CsesConnectionPanel(collab: _collab, onReset: _confirmReset, onReconnect: _host.reconnect),
                  if (_collab.error != null) ...[const SizedBox(height: 12), _ErrorBanner(message: _collab.error!)],
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
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
                            onPressed: _collab.initialized && !_collab.busy ? _openCollaborativeEditor : null,
                            icon: const Icon(Icons.edit_document),
                            label: Text(_collab.initialized ? '进入协同编辑' : '正在加载文档'),
                          ),
                          if (!_collab.initialized)
                            const Padding(padding: EdgeInsets.only(top: 12), child: Text('正在从 Rust/Yrs 加载本地文档……')),
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

  /// 先完成资源释放再返回登录页，避免下一账号登录后被旧宿主清理。
  Future<void> _logout() async {
    await _host.close();
    if (mounted) widget.onLogout?.call();
  }

  /// 打开独立正文页并注入宿主 Markdown 文件选择器；Future 在返回状态页时完成，控制器继续持有文档。
  Future<void> _openCollaborativeEditor() {
    FocusManager.instance.primaryFocus?.unfocus();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => CollaborativeEditorPage(collab: _collab, pickMarkdown: pickMarkdownFile),
      ),
    );
  }

  /// 确认后清理当前文档的本地更新，不删除服务端文档。
  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除本机 Demo 缓存？'),
        content: const Text('只删除这个客户端的 SQLite Update 日志，不会清理服务器内存中的文档。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清除')),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await _collab.resetLocalCache();
    }
  }
}

/// 主连接及协同阶段的紧凑显示。
class _StatusChip extends StatelessWidget {
  /// 显示 [status] 对应的标签和颜色。
  const _StatusChip({required this.status});

  /// 控制器持有的当前阶段。
  final ConnectionStatus status;

  @override
  /// 使用 [context] 渲染当前状态，无网络或缓存副作用。
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

/// 可操作失败信息的单一展示位置。
class _ErrorBanner extends StatelessWidget {
  /// 显示控制器提供的 [message]，不包含登录凭证。
  const _ErrorBanner({required this.message});

  /// 当前失败文案。
  final String message;

  @override
  /// 使用 [context] 渲染当前状态，无网络或缓存副作用。
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
      ),
    );
  }
}
