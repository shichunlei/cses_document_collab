import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/editor/collab_image_content.dart';
import 'package:cses_document_collab/src/editor/collab_unsupported_block.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// 使用现有可选择资源块外壳展示的媒体类型；正式图片额外包含尺寸和题注投影。
enum CollabEmbedKind {
  /// 离线草稿的独立链接卡片。
  link,

  /// 原有视频播放器。
  video,

  /// 正式 BlockCraft 图片容器，离线无专属投影时复用 AppFlowy 图片组件。
  image,
}

/// 构建可选中的链接、视频和正式图片；复用同一选区与资源块生命周期。
///
/// 资源地址通过节点 url 属性和 CollabBlock.text 传递；正式图片使用 props.src，视频使用 props.url，
/// 离线草稿使用私有 Y.Text，桥接调用方不直接解析共享类型。
/// 正式图片另携带布局和题注，写入原 props/children；不会把题注展平到根。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
/// final builder = CollabEmbedBlockComponentBuilder(kind: CollabEmbedKind.image);
/// // 将 builder 注册到所属 AppFlowyEditor 的 image 类型，无需单独 dispose。
/// ```
class CollabEmbedBlockComponentBuilder extends BlockComponentBuilder {
  /// [kind] 决定资源展示类型。
  /// [configuration] 提供现有选区外壳的布局；不创建 WS 或持有编辑器所有权。
  CollabEmbedBlockComponentBuilder({
    required this.kind,
    super.configuration = const BlockComponentConfiguration(),
  });

  /// 当前资源类型，正式图片采用专属布局投影。
  final CollabEmbedKind kind;

  /// 根据 [blockComponentContext] 创建借用节点的资源视图，离线图片沿用现有组件。
  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    if (kind == CollabEmbedKind.video) {
      final url = node.attributes[csesEmbedUrlAttribute];
      final uri = url is String ? Uri.tryParse(url) : null;
      if (uri == null || !_isSupportedNetworkUri(uri)) {
        return CollabUnsupportedBlockComponentBuilder().build(
          blockComponentContext,
        );
      }
    }
    if (kind == CollabEmbedKind.image &&
        node.attributes[collabImageAttribute] == null) {
      return ImageBlockComponentBuilder(
        configuration: configuration,
      ).build(blockComponentContext);
    }
    return _CollabEmbedBlockWidget(
      key: node.key,
      node: node,
      kind: kind,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      actionTrailingBuilder: (context, state) =>
          actionTrailingBuilder(blockComponentContext, state),
    );
  }

  /// 验证 UI 节点外壳；正式图片的 caption 由专属属性承载，真实父子关系留在 Rust。
  @override
  BlockComponentValidate get validate => (node) {
    final url = node.attributes[csesEmbedUrlAttribute];
    return node.children.isEmpty &&
        node.delta == null &&
        url is String &&
        (kind == CollabEmbedKind.image ||
            kind == CollabEmbedKind.video ||
            url.isNotEmpty);
  };
}

class _CollabEmbedBlockWidget extends BlockComponentStatefulWidget {
  const _CollabEmbedBlockWidget({
    super.key,
    required super.node,
    required this.kind,
    required super.configuration,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
  });

  final CollabEmbedKind kind;

  @override
  State<_CollabEmbedBlockWidget> createState() =>
      _CollabEmbedBlockWidgetState();
}

/// 借用编辑器节点展示资源；独占视频控制器，源变化或退出时释放，
/// 原位节点属性更新通过保存的源字符串检测，迟到初始化不覆盖当前资源。
class _CollabEmbedBlockWidgetState extends State<_CollabEmbedBlockWidget>
    with SelectableMixin, BlockComponentConfigurable {
  final GlobalKey _contentKey = GlobalKey();
  VideoPlayerController? _videoController;
  Object? _videoError;

  /// 已开始加载的源字符串；Node 为可变对象，不能从 oldWidget 恢复旧 URL。
  String? _videoSource;

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  String get _url =>
      widget.node.attributes[csesEmbedUrlAttribute] as String? ?? '';

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  /// 挂载时为视频创建独占播放器；其他资源不分配播放器或输入焦点。
  /// 原位属性变化的组件刷新由 AppFlowy BlockComponentContainer 的节点订阅负责。
  @override
  void initState() {
    super.initState();
    if (widget.kind == CollabEmbedKind.video) {
      unawaited(_initializeVideo());
    }
  }

  /// [oldWidget] 为同一状态的旧配置；即使其 Node 已被原位更新，也按保存的源
  /// 检测资源变化。只更新视频控制器，不重建正文或改变当前编辑选区。
  @override
  void didUpdateWidget(covariant _CollabEmbedBlockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.kind == CollabEmbedKind.video && _videoSource != _url) {
      unawaited(_initializeVideo());
    }
  }

  /// 为当前源替换播放器，Future 在旧资源释放及新资源初始化后完成。
  /// 首次 await 前交接控制器所有权，使快速 A→B→A 更新和页面退出都能释放各自
  /// 资源；异步边界按控制器身份阻止旧结果回写。无效 URL 展示占位，不写协同文档。
  /// 播放器失败由本地异常边界记录并展示，后台 Future 不向 UI 事件循环泄漏异常。
  Future<void> _initializeVideo() async {
    final previousController = _videoController;
    final source = _url;
    _videoSource = source;
    final uri = Uri.tryParse(source);
    final controller = uri != null && _isSupportedNetworkUri(uri)
        ? VideoPlayerController.networkUrl(uri)
        : null;
    _videoController = controller;
    _videoError = null;
    await _disposeVideo(previousController);
    if (!mounted ||
        !identical(_videoController, controller) ||
        _videoSource != source) {
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
      CollabDiagnostics.report(
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
  /// 每个控制器只交接一次。Future 在释放或记录失败后完成，不使用媒体 URL 作为日志。
  Future<void> _disposeVideo(VideoPlayerController? controller) async {
    if (controller == null) return;
    try {
      await controller.dispose();
    } catch (error, stackTrace) {
      CollabDiagnostics.report(
        '文档视频资源释放失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
    }
  }

  /// 使用 [context] 渲染资源内容、更多插入入口及选区外壳，不创建主连接。
  @override
  Widget build(BuildContext context) {
    final editorState = context.read<EditorState>();
    final child = switch (widget.kind) {
      CollabEmbedKind.link => _buildLinkCard(context),
      CollabEmbedKind.video => _buildVideoCard(context),
      CollabEmbedKind.image => CollabImageContent(
        node: node,
        editorState: editorState,
      ),
    };

    Widget selectableChild = Padding(
      key: _contentKey,
      padding: padding,
      child: Stack(
        children: [
          child,
          Positioned(
            top: 4,
            right: widget.kind == CollabEmbedKind.video ? 60 : 4,
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              child: CollabBlockMoreButton(
                key: ValueKey(
                  'block-more-${node.attributes['cses_collab_block_id'] ?? node.id}',
                ),
                editor: editorState,
                node: node,
              ),
            ),
          ),
        ],
      ),
    );
    selectableChild = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      cursorColor: editorState.editorStyle.cursorColor,
      selectionColor: editorState.editorStyle.selectionColor,
      supportTypes: const [
        BlockSelectionType.block,
        BlockSelectionType.cursor,
        BlockSelectionType.selection,
      ],
      child: selectableChild,
    );

    if (widget.showActions && widget.actionBuilder != null) {
      selectableChild = BlockComponentActionWrapper(
        node: node,
        actionBuilder: widget.actionBuilder!,
        actionTrailingBuilder: widget.actionTrailingBuilder,
        child: selectableChild,
      );
    }
    return selectableChild;
  }

  Widget _buildLinkCard(BuildContext context) {
    final uri = Uri.tryParse(_url);
    final displayHost = uri?.host.isNotEmpty == true ? uri!.host : '外部链接';
    return Material(
      color: const Color(0xFFF5F7FB),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: const ValueKey('collab-link-block-open'),
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openExternally(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFFDBEAFE),
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.link, color: Color(0xFF2563EB)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayHost,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.open_in_new, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoCard(BuildContext context) {
    final controller = _videoController;
    final initialized = controller?.value.isInitialized == true;
    if (!initialized) {
      return _VideoPlaceholder(
        url: _url,
        hasError: _videoError != null,
        onOpen: () => _openExternally(context),
      );
    }

    final aspectRatio = controller!.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: Colors.black,
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(controller),
              Center(
                child: IconButton.filled(
                  key: const ValueKey('collab-video-block-play'),
                  tooltip: controller.value.isPlaying ? '暂停' : '播放',
                  onPressed: () async {
                    if (controller.value.isPlaying) {
                      await controller.pause();
                    } else {
                      await controller.play();
                    }
                    if (mounted) {
                      setState(() {});
                    }
                  },
                  icon: Icon(
                    controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                ),
              ),
              Positioned(
                right: 6,
                top: 6,
                child: IconButton.filledTonal(
                  tooltip: '在外部应用打开',
                  onPressed: () => _openExternally(context),
                  icon: const Icon(Icons.open_in_new, size: 18),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openExternally(BuildContext context) async {
    final uri = Uri.tryParse(_url);
    final opened =
        uri != null &&
        _isSupportedNetworkUri(uri) &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('无法打开该链接')));
    }
  }

  @override
  Position start() => Position(path: node.path, offset: 0);

  @override
  Position end() => Position(path: node.path, offset: 1);

  @override
  Position getPositionInOffset(Offset offset) => end();

  @override
  bool get shouldCursorBlink => false;

  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) =>
      getRectsInSelection(Selection.invalid()).first;

  @override
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) {
    if (_renderBox == null) {
      return null;
    }
    return getRectsInSelection(
      Selection.collapsed(position),
      shiftWithBaseOffset: shiftWithBaseOffset,
    ).firstOrNull;
  }

  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) {
    if (_renderBox == null) {
      return const [];
    }
    final parentBox = context.findRenderObject();
    final contentBox = _contentKey.currentContext?.findRenderObject();
    if (parentBox is RenderBox && contentBox is RenderBox) {
      final offset = shiftWithBaseOffset
          ? contentBox.localToGlobal(Offset.zero, ancestor: parentBox)
          : Offset.zero;
      return [offset & contentBox.size];
    }
    return [Offset.zero & _renderBox!.size];
  }

  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: node.path, startOffset: 0, endOffset: 1);

  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      _renderBox!.localToGlobal(offset);

  @override
  TextDirection textDirection() => TextDirection.ltr;

  /// 退出时解除当前控制器引用并启动拥有资源的释放；初始化回调由 mounted/身份
  /// 检查失效，释放失败由资源边界记录，不修改借用的编辑器、节点或 WS。
  @override
  void dispose() {
    final controller = _videoController;
    _videoController = null;
    unawaited(_disposeVideo(controller));
    super.dispose();
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({
    required this.url,
    required this.hasError,
    required this.onOpen,
  });

  final String url;
  final bool hasError;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              hasError ? Icons.broken_image_outlined : Icons.movie_outlined,
              color: Colors.white,
              size: 42,
            ),
            const SizedBox(height: 10),
            Text(
              hasError ? '视频加载失败' : '正在加载视频…',
              style: const TextStyle(color: Colors.white),
            ),
            if (hasError) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new, size: 17),
                label: const Text('外部打开'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

bool _isSupportedNetworkUri(Uri uri) =>
    (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
