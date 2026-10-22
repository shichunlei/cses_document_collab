import 'dart:async';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_connection_panel.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_host.dart';
import 'package:flutter/material.dart';

import 'markdown_file_picker.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_page.dart';

/// 登录后的连接首页；通过文档列表选择协同文档，另提供独立离线编辑入口。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/collab_demo_page.dart';
/// import 'package:flutter/material.dart';
/// const app = MaterialApp(home: CollabDemoPage());
/// // 页面卸载时释放协同资源，离线制图会话由包的路由入口释放。
/// ```
class CollabDemoPage extends StatefulWidget {
  /// 创建连接首页；账号主连接随本页释放，文档控制器由列表选择后创建。
  /// [key] 控制组件身份与状态复用，[localDraft] 默认为false，true使用本地协同草稿。
  /// [onLogout] 在退出并释放协同资源后调用，null隐藏退出按钮。
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

  /// 从打开制图到关闭结果页期间锁定入口，避免快速点击创建多个本地会话。
  bool _openingImageComposer = false;

  /// 从打开列表到退出列表期间锁定入口，避免重复回调堆叠多个列表路由。
  bool _openingDocumentList = false;

  @override
  /// 准备账号服务并启动主连接；正式文档由列表选择后加载。
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
  /// 使用 [context] 渲染协同状态；离线入口不依赖协同文档是否加载成功。
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _host,
      builder: (context, _) {
        final controller = _host.controller;
        final coordinator = _host.creation;
        return Scaffold(
          appBar: AppBar(
            title: const Text('CSES 协同 Demo'),
            actions: [
              if (widget.onLogout != null)
                IconButton(onPressed: _logout, tooltip: '退出登录', icon: const Icon(Icons.logout)),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _host.error ??
                        (coordinator != null
                            ? '主连接已启动，请从文档列表选择文档'
                            : widget.localDraft && controller?.initialized == true
                            ? '本地预览已就绪'
                            : '正在初始化连接…'),
                  ),
                  if (!widget.localDraft)
                    OutlinedButton(
                      key: const ValueKey('retry-connection'),
                      onPressed: coordinator?.busy == true ? null : _host.reconnect,
                      child: const Text('重新连接'),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('open-document-list'),
                    onPressed: coordinator == null || coordinator.busy || _openingDocumentList
                        ? null
                        : _openDocumentList,
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('文档列表'),
                  ),
                  if (coordinator?.pending == true)
                    TextButton(
                      onPressed: coordinator!.busy || _openingDocumentList
                          ? null
                          : _openDocumentList,
                      child: const Text('上次创建尚未完成，点击继续'),
                    ),
                  if (controller != null) ...[
                    const SizedBox(height: 16),
                    CsesConnectionPanel(
                      collab: controller,
                      onReset: _confirmReset,
                      onReconnect: _host.reconnect,
                    ),
                  ],
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

  /// 打开文档列表和新建入口；编辑页只能由列表的选择回调推入。
  /// 返回时保留账号主连接，列表与编辑页借用的控制器均由宿主释放。
  Future<void> _openDocumentList() async {
    final coordinator = _host.creation;
    if (!mounted || coordinator == null || coordinator.busy || _openingDocumentList) return;
    setState(() => _openingDocumentList = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (listContext) => DocumentCreationPage(
            coordinator: coordinator,
            loadTargets: _host.loadCreationTargets,
            loadDocuments: _host.loadCreationDocuments,
            onOpenDocument: (documentId) => _openListedDocument(listContext, documentId),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingDocumentList = false);
    }
  }

  /// 从[listContext]所在列表打开[documentId]并借用正式控制器展示编辑页。
  /// Future等待编辑页退出；旧路由或关闭宿主不导航，失败抛固定FormatException供列表重试。
  Future<void> _openListedDocument(BuildContext listContext, String documentId) async {
    if (!mounted || !listContext.mounted || ModalRoute.of(listContext)?.isCurrent != true) {
      throw const FormatException('请返回文档列表后重新打开');
    }
    final opened = await _host.openListedDocument(documentId);
    if (opened != documentId) {
      throw FormatException(_host.creation?.error ?? '文档打开失败，请重试');
    }
    if (!mounted || !listContext.mounted || ModalRoute.of(listContext)?.isCurrent != true) {
      throw const FormatException('文档已就绪，请返回列表后重新打开');
    }
    final controller = _host.controller;
    if (controller == null || controller.documentId != documentId || !controller.initialized) {
      throw const FormatException('文档尚未就绪，请重试');
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(listContext).push<void>(
      MaterialPageRoute(
        builder: (_) => CollaborativeEditorPage(collab: controller, pickMarkdown: pickMarkdownFile),
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
