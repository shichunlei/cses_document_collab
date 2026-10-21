import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart'
    show AppFlowyBlockEditorAdapter, csesEmbedUrlAttribute, csesVideoBlockType;
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_media_block_base.dart';
import 'package:cses_document_collab/src/editor/collab_unsupported_block.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_lock_overlay.dart';
import 'package:cses_document_collab/src/ui/modal/collab_media_timeline.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

/// 视频块独立构建器，保留原网络校验、播放器、菜单和布局配置。
/// 手机卡片外框固定16:9，原始画面等比居中显示，不改写共享视频尺寸属性。
/// 不创建主连接或持有编辑器；具体状态拥有并释放播放器。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_video_block.dart';
/// final builder = CollabVideoBlockComponentBuilder();
/// // 注册到 AppFlowyEditor.blockComponentBuilders['video']。
/// ```
class CollabVideoBlockComponentBuilder extends BlockComponentBuilder {
  /// [configuration]沿用原媒体默认布局和选区配置，不分配播放器资源。
  CollabVideoBlockComponentBuilder({super.configuration = const BlockComponentConfiguration()});

  /// 保持原视频的无正文、无子块、字符串地址外壳校验。
  @override
  BlockComponentValidate get validate =>
      (node) => node.children.isEmpty && node.delta == null && node.attributes[csesEmbedUrlAttribute] is String;

  /// 使用借用[context]创建原视频卡片；非HTTP(S)或缺少host的地址仍显示保护性占位。
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    final node = context.node;
    final url = node.attributes[csesEmbedUrlAttribute];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || !isCollabMediaNetworkUri(uri)) {
      return CollabUnsupportedBlockComponentBuilder().build(context);
    }
    return _VideoBlock(
      key: node.key,
      node: node,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (anchor, state) => actionBuilder(context, state),
      actionTrailingBuilder: (anchor, state) => actionTrailingBuilder(context, state),
    );
  }
}

/// 借用原节点与工具栏配置的视频组件，不在构造阶段分配控制器。
class _VideoBlock extends CollabMediaBlock {
  /// [key]控制身份复用；[node]/[configuration]、[showActions]、[actionBuilder]和
  /// [actionTrailingBuilder]均为编辑器提供的借用配置和回调。
  const _VideoBlock({
    super.key,
    required super.node,
    required super.configuration,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
  });

  /// 创建独占原播放器资源的状态。
  @override
  createState() => _VideoBlockState();
}

/// 独占视频控制器；原源切换、迟到结果保护及等待跳转后释放流程保持不变。
class _VideoBlockState extends CollabMediaBlockState<_VideoBlock> {
  /// 当前State独占的播放器；替换或退出时交接一次释放。
  VideoPlayerController? _videoController;

  /// 当前源的初始化错误，旧源结果不能覆盖此值。
  Object? _videoError;

  /// 按控制器记录仍在执行的跳转；资源释放前等待对应Future，避免关闭后访问播放器。
  final _videoSeeks = <VideoPlayerController, Future<void>>{};

  /// 已开始加载的源字符串；Node 为可变对象，不能从 oldWidget 恢复旧 URL。
  String? _videoSource;

  /// 挂载时为当前视频创建独占播放器；初始化结果仍由身份与mounted保护。
  /// 原位属性变化的组件刷新由 AppFlowy BlockComponentContainer 的节点订阅负责。
  @override
  void initState() {
    super.initState();
    unawaited(_initializeVideo());
  }

  /// [oldWidget] 为同一状态的旧配置；即使其 Node 已被原位更新，也按保存的源
  /// 检测资源变化。只更新视频控制器，不重建正文或改变当前编辑选区。
  @override
  void didUpdateWidget(covariant _VideoBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_videoSource != url) {
      unawaited(_initializeVideo());
    }
  }

  /// 为当前源替换播放器，Future 在旧资源释放及新资源初始化后完成。
  /// 首次 await 前交接控制器所有权，使快速 A→B→A 更新和页面退出都能释放各自
  /// 资源；异步边界按控制器身份阻止旧结果回写。无效 URL 展示占位，不写协同文档。
  /// 播放器失败由本地异常边界记录并展示，后台 Future 不向 UI 事件循环泄漏异常。
  Future<void> _initializeVideo() async {
    final previousController = _videoController;
    final source = url;
    _videoSource = source;
    final uri = Uri.tryParse(source);
    final controller = uri != null && isCollabMediaNetworkUri(uri) ? VideoPlayerController.networkUrl(uri) : null;
    _videoController = controller;
    _videoError = null;
    await _disposeVideo(previousController);
    if (!mounted || !identical(_videoController, controller) || _videoSource != source) {
      return;
    }

    if (controller == null) {
      setState(() => _videoError = const FormatException('无效的视频链接'));
      return;
    }

    try {
      await controller.initialize();
      if (!mounted || !identical(_videoController, controller)) return;
      await controller.setLooping(false);
    } catch (error, stackTrace) {
      if (!mounted || !identical(_videoController, controller)) return;
      _videoError = error;
      EditorCommandContext.report(
        mounted ? context.read<EditorState>() : null,
        '文档视频加载失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
    }
    if (mounted && identical(_videoController, controller)) {
      setState(() {});
    }
  }

  /// 释放本视图拥有的 [controller]，null 表示没有资源；调用方先解除当前引用，
  /// 每个控制器只交接一次，先等待其跳转完成。Future在释放或记录失败后完成。
  Future<void> _disposeVideo(VideoPlayerController? controller) async {
    if (controller == null) return;
    final pending = _videoSeeks[controller];
    if (pending != null) {
      try {
        await pending;
      } catch (error, stackTrace) {
        EditorCommandContext.report(
          mounted ? context.read<EditorState>() : null,
          '视频关闭前跳转失败',
          error: error,
          stackTrace: stackTrace,
          tag: 'DocCollab',
        );
      }
    }
    try {
      await controller.dispose();
    } catch (error, stackTrace) {
      EditorCommandContext.report(
        mounted ? context.read<EditorState>() : null,
        '文档视频资源释放失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
    }
  }

  /// 使用借用的[context]展示视频、直接播放按钮和画面内底部进度条，编辑/预览均可播放。
  /// 高频播放位置仅更新进度区域；视频控制器仍由此State创建与释放。
  /// 外框与加载/失败占位统一固定16:9；画面按原始比例居中完整显示，空余区域留黑，不拉伸或裁切。
  /// 播放按钮相对整个16:9外框水平、垂直居中；进度条固定底部，时间标签位于轨道上方。
  Widget _buildVideoCard(BuildContext context) {
    final controller = _videoController;
    if (controller?.value.isInitialized != true) {
      return _VideoPlaceholder(url: url, hasError: _videoError != null);
    }

    final sourceAspectRatio = controller!.value.aspectRatio > 0 ? controller.value.aspectRatio : 16 / 9;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: Colors.black,
        child: AspectRatio(
          key: const ValueKey('collab-video-viewport'),
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(aspectRatio: sourceAspectRatio, child: VideoPlayer(controller)),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                  child: CollabMediaTimeline(
                    mediaKind: 'video',
                    overlay: true,
                    key: ObjectKey(controller),
                    controller: controller,
                    onSeek: (target) => _seekVideo(controller, target),
                  ),
                ),
              ),
              Center(
                child: ExcludeFocus(
                  child: ValueListenableBuilder<VideoPlayerValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => IconButton.filled(
                      key: const ValueKey('collab-video-block-play'),
                      tooltip: value.isPlaying ? '暂停' : '播放',
                      onPressed: _toggleVideo,
                      icon: Icon(value.isPlaying ? LucideIcons.pause : LucideIcons.play),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 在视频交互开始时清除正文选区并关闭编辑器输入，不改写正文或历史。
  /// 只解除借用编辑器自身的焦点，不阻止播放、跳转或滚动，也不安排自动恢复焦点。
  void _suppressVideoFocus() {
    if (!mounted) return;
    final editor = context.read<EditorState>();
    if (editor.isDisposed) return;
    editor.selection = null;
    editor.service.keyboardService
      ?..closeKeyboard()
      ..disable(disposition: UnfocusDisposition.scope);
  }

  /// 对借用[controller]跳转到[target]；仅当前播放器可开始新任务。
  /// 跳转前屏蔽正文焦点；返回的Future与资源释放共享，完成前不得销毁该控制器；错误交给进度视图提示。
  Future<void> _seekVideo(VideoPlayerController controller, Duration target) async {
    if (!mounted || !identical(controller, _videoController)) return;
    _suppressVideoFocus();
    final operation = controller.seekTo(target);
    _videoSeeks[controller] = operation;
    try {
      await operation;
    } finally {
      if (identical(_videoSeeks[controller], operation)) {
        _videoSeeks.remove(controller);
      }
    }
  }

  /// Toggles the current owned player directly; replaced/disposed controllers
  /// never refresh the view. Suppresses body focus before playback; failures are reported and shown locally.
  Future<void> _toggleVideo() async {
    if (!mounted) return;
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    _suppressVideoFocus();
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        await controller.play();
      }
      if (mounted && identical(_videoController, controller)) setState(() {});
    } catch (error, stackTrace) {
      if (!mounted || !identical(_videoController, controller)) return;
      EditorCommandContext.report(
        mounted ? context.read<EditorState>() : null,
        '视频播放操作失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('播放操作失败，请重试')));
    }
  }

  /// 退出时解除当前控制器引用并启动拥有资源的释放；初始化回调由 mounted/身份
  /// 检查失效，释放失败由资源边界记录，不修改借用的编辑器、节点或 WS。
  @override
  void dispose() {
    final controller = _videoController;
    _videoController = null;
    unawaited(_disposeVideo(controller));
    super.dispose();
  }

  /// 在借用[context]中构建视频及加载/失败占位，阻止画面点击成为正文选区手势。
  /// 指针按下即收起正文输入，子控件继续处理播放及拖动；不恢复焦点或拦截滚动。
  /// 锁标独立覆盖在16:9画面右上角，加载和失败状态保持相同定位且不受内容圆角裁剪。
  @override
  Widget buildMedia(BuildContext context) => ExcludeFocus(
    child: Listener(
      onPointerDown: (_) => _suppressVideoFocus(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: _suppressVideoFocus,
        child: CollabCardLockOverlay(child: _buildVideoCard(context)),
      ),
    ),
  );

  /// 在借用[context]中创建视频更多菜单；外部打开在预览中可用，链接复制和删除仅编辑状态显示。
  /// 复制链接及删除在面板完整退场并通过菜单身份/权限校验后执行，直接播放仍位于视频画面内。
  @override
  Widget? buildMediaActions(BuildContext context) {
    final host = collabBlockActionContext(context);
    final editor = context.read<EditorState>();
    final id = node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] as String? ?? node.id;
    return buildMediaMore(
      context,
      readOnlyActions: [
        (
          label: '在外部应用打开',
          key: const ValueKey('collab-video-open'),
          run: () => openExternally(collabBlockActionContext(context)),
        ),
      ],
      actions: [
        if (url.trim().isNotEmpty)
          (label: '复制链接', key: ValueKey('media-copy-link-$id'), run: () => copyCollabMediaLink(host, editor, node)),
        (label: '删除视频', key: const ValueKey('collab-video-menu-delete'), run: () => _deleteVideoBlock(editor, id)),
      ],
    );
  }
}

/// 删除借用[editor]中稳定[blockId]对应的视频引用，不删除上传文件或业务资源。
/// 仅处理根/高亮容器中的当前视频；关闭、只读、已删或类型变化时不执行。
/// 末个子块补稳定身份空段落，与删除组成独立撤销事务；不主动恢复正文输入。
/// Future在事务完成后结束，异常交由更多菜单报告，播放器仍由视频组件销毁时释放。
Future<void> _deleteVideoBlock(EditorState editor, String blockId) async {
  if (editor.isDisposed || !editor.editable) return;
  final source = findCollabActionNode(editor, blockId);
  if (source == null || source.type != csesVideoBlockType || !const {'page', 'callout'}.contains(source.parent?.type)) {
    return;
  }
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  final transaction = editor.transaction..deleteNode(source);
  if (source.parent!.children.length == 1) {
    final paragraph = paragraphNode();
    paragraph.updateAttributes({AppFlowyBlockEditorAdapter.collabBlockIdAttribute: paragraph.id});
    transaction.add(InsertOperation(source.path, [paragraph]), transform: false);
  }
  transaction.afterSelection = null;
  await editor.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
}

/// Displays loading/failure status without a second operation button.
class _VideoPlaceholder extends StatelessWidget {
  /// [url] labels failed content; [hasError] selects failure rather than loading.
  const _VideoPlaceholder({required this.url, required this.hasError});

  /// Borrowed source URL, displayed only on failure.
  final String url;

  /// Whether initialization failed; false displays loading.
  final bool hasError;

  /// 使用借用的[context]构建固定16:9状态外框，加载或失败均保持后续正文位置。
  /// 窄屏大字下仅在说明超出可用高度时等比缩小占位内容，避免溢出画面。
  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      key: const ValueKey('collab-video-viewport'),
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(14)),
        child: LayoutBuilder(
          builder: (context, constraints) => Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: constraints.maxWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(hasError ? LucideIcons.imageOff : LucideIcons.film, color: Colors.white, size: 42),
                    const SizedBox(height: 10),
                    Text(hasError ? '视频加载失败' : '正在加载视频…', style: const TextStyle(color: Colors.white)),
                    if (hasError) ...[
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
