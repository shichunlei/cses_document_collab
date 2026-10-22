import 'dart:async';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_connection_panel.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_host.dart';
import 'package:flutter/material.dart';

import 'markdown_file_picker.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_page.dart';

/// 登录后的文档入口，拥有协同控制器并提供独立的离线本地编辑入口。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/collab_demo_page.dart';
/// import 'package:flutter/material.dart';
/// const app = MaterialApp(home: CollabDemoPage(localDraft: true));
/// // 页面卸载时释放协同资源，离线制图会话由包的路由入口释放。
/// ```
class CollabDemoPage extends StatefulWidget {
  /// 创建文档状态页；控制器随此页生命周期创建与释放。
  /// [key] 控制组件身份与状态复用，[localDraft] 默认为false，true使用本地协同草稿。
  /// [onLogout] 在退出并释放协同资源后调用，null隐藏退出按钮。
  /// [initialDocumentId]显式指定正式文档，null恢复账号最近新建文档或Demo默认文档。
  const CollabDemoPage({super.key, this.localDraft = false, this.onLogout, this.initialDocumentId});

  /// 离线预览和测试可显式打开本地草稿；正式文档直接使用 Common 上下文。
  final bool localDraft;

  /// 入口指定的正式docId，默认由宿主恢复最近创建记录。
  final String? initialDocumentId;

  /// 返回登录页；移除本页会释放协同控制器及共享连接。
  final VoidCallback? onLogout;

  @override
  /// 创建本页资源所有者。
  createState() => _CollabDemoPageState();
}

/// 持有唯一协同控制器，进入正文页时借用同一实例。
class _CollabDemoPageState extends State<CollabDemoPage> {
  late final DemoDocumentHost _host;

  /// 从打开制图到关闭结果页期间锁定入口，避免快速点击创建多个本地会话。
  bool _openingImageComposer = false;

  /// Controller borrowed from the demo composition root.
  CollabController get _collab => _host.controller!;

  @override
  /// 初始化本地文档，随后使用登录会话自动连接。
  void initState() {
    super.initState();
    _host = DemoDocumentHost(
      localDraft: widget.localDraft,
      initialDocumentId: widget.initialDocumentId,
    );
    unawaited(_host.initialize());
  }

  @override
  /// 释放本页创建的编辑器控制器及协同会话。
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  @override
  /// 使用 [context] 渲染协同状态；离线入口不依赖协同文档是否加载成功。
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _host,
      builder: (context, _) {
        if (_host.controller == null) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('CSES 协同 Demo'),
              actions: [
                if (widget.onLogout != null)
                  IconButton(onPressed: _logout, tooltip: '退出登录', icon: const Icon(Icons.logout)),
              ],
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_host.error ?? '正在加载文档…'),
                  if (_host.error != null)
                    OutlinedButton(
                      key: const ValueKey('retry-document-open'),
                      onPressed: _host.creation?.busy == true ? null : _host.reconnect,
                      child: const Text('重试打开文档'),
                    ),
                  if (_host.creation != null) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _host.creation!.busy ? null : _openDocumentCreation,
                      icon: const Icon(Icons.note_add_outlined),
                      label: const Text('新建空白文档'),
                    ),
                  ],
                  const FilledButton(
                    onPressed: null,
                    key: ValueKey('open-collaborative-editor'),
                    child: Text('正在加载文档'),
                  ),
                  const SizedBox(height: 16),
                  _OfflineImageComposerCard(
                    busy: _openingImageComposer,
                    onOpen: _openOfflineImageComposer,
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
              if (_host.creation != null)
                IconButton(
                  key: const ValueKey('new-formal-document'),
                  onPressed: _host.creation!.busy ? null : _openDocumentCreation,
                  tooltip: _host.creation!.pending ? '继续完成新建文档' : '新建空白文档',
                  icon: const Icon(Icons.note_add_outlined),
                ),
              if (widget.onLogout != null)
                IconButton(
                  onPressed: _collab.busy ? null : _logout,
                  tooltip: '退出登录',
                  icon: const Icon(Icons.logout),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _StatusChip(status: _collab.status, editable: _collab.canEdit),
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
                  if (_host.creation?.pending == true) ...[
                    TextButton(
                      onPressed: _host.creation!.busy ? null : _openDocumentCreation,
                      child: const Text('上次创建尚未完成，点击继续'),
                    ),
                    if (_host.creation?.error != null) Text(_host.creation!.error!),
                  ],
                  CsesConnectionPanel(
                    collab: _collab,
                    onReset: _confirmReset,
                    onReconnect: _host.reconnect,
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
                            style: Theme.of(
                              context,
                            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
                            onPressed: _collab.initialized && !_collab.busy
                                ? _openCollaborativeEditor
                                : null,
                            icon: const Icon(Icons.edit_document),
                            label: Text(_collab.initialized ? '进入协同编辑' : '正在加载文档'),
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
                  const SizedBox(height: 16),
                  _OfflineImageComposerCard(
                    busy: _openingImageComposer,
                    onOpen: _openOfflineImageComposer,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 打开包内本地编辑与模板预览；返回首页不导出图片，失败在首页提示。
  /// 等待每个路由退出后再解锁入口，页面卸载后忽略迟到的结果。
  Future<void> _openOfflineImageComposer() async {
    if (_openingImageComposer) return;
    setState(() => _openingImageComposer = true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await showCollabImageComposer(context: context);
    } catch (error, stack) {
      debugPrint('离线本地编辑失败：$error\n$stack');
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('本地编辑失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _openingImageComposer = false);
    }
  }

  /// 先完成资源释放再返回登录页，避免下一账号登录后被旧宿主清理。
  Future<void> _logout() async {
    await _host.close();
    if (mounted) widget.onLogout?.call();
  }

  /// 打开宿主新建页面；成功返回后进入已安装的正式控制器，迟到结果不导航。
  Future<void> _openDocumentCreation() async {
    final coordinator = _host.creation;
    if (coordinator == null || coordinator.busy) return;
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => DocumentCreationPage(
          coordinator: coordinator,
          loadTargets: _host.loadCreationTargets,
          loadDocuments: _host.loadCreationDocuments,
        ),
      ),
    );
    if (!mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        id == null ||
        _host.controller?.documentId != id) {
      return;
    }
    await _openCollaborativeEditor();
  }

  /// 借用当前固定控制器打开正文页并注入Markdown选择器；失效或忙碌时不导航。
  /// Future在返回时完成，路由构建不重新读取可变的文档指针。
  Future<void> _openCollaborativeEditor() {
    final controller = _host.controller;
    if (controller == null || !controller.initialized || controller.busy) {
      return Future<void>.value();
    }
    FocusManager.instance.primaryFocus?.unfocus();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            CollaborativeEditorPage(collab: controller, pickMarkdown: pickMarkdownFile),
      ),
    );
  }

  /// 只清理确认时借用的同一文档；期间切换文档或开始创建则取消，不删除服务端文档。
  Future<void> _confirmReset() async {
    final controller = _host.controller;
    if (controller == null || controller.busy || _host.creation?.busy == true) {
      return;
    }
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
    if (mounted &&
        confirmed == true &&
        identical(controller, _host.controller) &&
        !controller.busy &&
        _host.creation?.busy != true) {
      await controller.resetLocalCache();
    }
  }
}

/// 首页的本地制图卡片，加载失败和正常协同状态共用同一交互。
class _OfflineImageComposerCard extends StatelessWidget {
  /// [busy] 控制重复打开，[onOpen] 在点击入口时启动独立本地会话。
  const _OfflineImageComposerCard({required this.busy, required this.onOpen});

  /// 当前首页是否已有制图或结果路由，由首页持有。
  final bool busy;

  /// 点击“开始离线编辑”时调用，协同连接状态不影响可用性。
  final VoidCallback onOpen;

  /// 使用 [context] 的主题展示入口与本地处理说明。
  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '离线本地编辑',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text('本地编辑文字并预览模板，无需连接服务端。', style: Theme.of(context).textTheme.bodySmall),
            const Divider(height: 28),
            FilledButton.icon(
              key: const ValueKey('open-offline-image-composer'),
              onPressed: busy ? null : onOpen,
              icon: const Icon(Icons.image_outlined),
              label: const Text('开始离线编辑'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 主连接及协同阶段的紧凑显示。
class _StatusChip extends StatelessWidget {
  /// 显示[status]对应的标签和颜色；[editable]用于区分离线编辑与只读。
  const _StatusChip({required this.status, required this.editable});

  /// 控制器持有的当前阶段。
  final ConnectionStatus status;

  /// 控制器的当前编辑能力，由宿主持有。
  final bool editable;

  @override
  /// 使用 [context] 渲染当前状态，无网络或缓存副作用。
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ConnectionStatus.starting => ('初始化', Colors.blueGrey),
      ConnectionStatus.connecting => ('连接中', Colors.orange),
      ConnectionStatus.online => ('在线', Colors.green),
      ConnectionStatus.offline => (editable ? '离线可编辑' : '离线只读', Colors.blueGrey),
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
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
        ),
      ),
    );
  }
}
