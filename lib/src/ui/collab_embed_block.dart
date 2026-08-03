import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// URL-backed block presentations that AppFlowy does not provide as standard
/// components. Body images remain excluded because AppFlowy's native image
/// block already handles loading, resizing and block selection.
enum CollabEmbedKind { cover, link, video }

typedef CollabCoverEditCallback =
    void Function(BuildContext context, EditorState editorState, Node node);

/// Builds a selectable collaborative link or video block.
///
/// Both block kinds keep their URL in [csesEmbedUrlAttribute]. The adapter
/// mirrors that value into `CollabBlock.text`, so the existing Rust/Yrs schema
/// can synchronize these blocks without adding another bridge field.
class CollabEmbedBlockComponentBuilder extends BlockComponentBuilder {
  CollabEmbedBlockComponentBuilder({
    required this.kind,
    this.onEditCover,
    super.configuration = const BlockComponentConfiguration(),
  });

  final CollabEmbedKind kind;
  final CollabCoverEditCallback? onEditCover;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    final node = blockComponentContext.node;
    return _CollabEmbedBlockWidget(
      key: node.key,
      node: node,
      kind: kind,
      onEditCover: onEditCover,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (context, state) =>
          actionBuilder(blockComponentContext, state),
      actionTrailingBuilder: (context, state) =>
          actionTrailingBuilder(blockComponentContext, state),
    );
  }

  @override
  BlockComponentValidate get validate => (node) {
    final url = node.attributes[csesEmbedUrlAttribute];
    return node.children.isEmpty &&
        node.delta == null &&
        url is String &&
        (kind == CollabEmbedKind.cover || url.isNotEmpty);
  };
}

class _CollabEmbedBlockWidget extends BlockComponentStatefulWidget {
  const _CollabEmbedBlockWidget({
    super.key,
    required super.node,
    required this.kind,
    this.onEditCover,
    required super.configuration,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
  });

  final CollabEmbedKind kind;
  final CollabCoverEditCallback? onEditCover;

  @override
  State<_CollabEmbedBlockWidget> createState() =>
      _CollabEmbedBlockWidgetState();
}

class _CollabEmbedBlockWidgetState extends State<_CollabEmbedBlockWidget>
    with SelectableMixin, BlockComponentConfigurable {
  final GlobalKey _contentKey = GlobalKey();
  VideoPlayerController? _videoController;
  Object? _videoError;

  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  @override
  Node get node => widget.node;

  String get _url =>
      widget.node.attributes[csesEmbedUrlAttribute] as String? ?? '';

  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  @override
  void initState() {
    super.initState();
    if (widget.kind == CollabEmbedKind.video) {
      unawaited(_initializeVideo());
    }
  }

  @override
  void didUpdateWidget(covariant _CollabEmbedBlockWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldUrl = oldWidget.node.attributes[csesEmbedUrlAttribute];
    if (widget.kind == CollabEmbedKind.video && oldUrl != _url) {
      // A remote Yrs update can replace a block URL while this state remains
      // mounted. Recreating the controller prevents playback from continuing
      // against the stale resource.
      unawaited(_initializeVideo());
    }
  }

  Future<void> _initializeVideo() async {
    final previousController = _videoController;
    _videoController = null;
    _videoError = null;
    await previousController?.dispose();

    final uri = Uri.tryParse(_url);
    if (uri == null || !_isSupportedNetworkUri(uri)) {
      if (mounted) {
        setState(() => _videoError = const FormatException('无效的视频链接'));
      }
      return;
    }

    final controller = VideoPlayerController.networkUrl(uri);
    _videoController = controller;
    try {
      await controller.initialize();
      await controller.setLooping(false);
    } catch (error) {
      // Invalid media, unsupported codecs and network failures all stay local
      // rendering concerns. The URL remains in the document and can still be
      // opened externally or repaired by another client.
      _videoError = error;
    }
    if (mounted && identical(_videoController, controller)) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final editorState = context.read<EditorState>();
    final child = switch (widget.kind) {
      CollabEmbedKind.cover => _buildCover(context, editorState),
      CollabEmbedKind.link => _buildLinkCard(context),
      CollabEmbedKind.video => _buildVideoCard(context),
    };

    Widget selectableChild = Padding(
      key: _contentKey,
      padding: padding,
      child: child,
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

  Widget _buildCover(BuildContext context, EditorState editorState) {
    final canEdit = editorState.editable && widget.onEditCover != null;
    if (_url.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('collab-document-cover-add'),
          onPressed: canEdit
              ? () => widget.onEditCover!(context, editorState, node)
              : null,
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
          label: const Text('添加封面'),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF64748B),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: AspectRatio(
        aspectRatio: 2.15,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              _url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const ColoredBox(
                color: Color(0xFFF1F5F9),
                child: Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: Color(0xFF94A3B8),
                    size: 42,
                  ),
                ),
              ),
            ),
            if (canEdit)
              Positioned(
                right: 12,
                bottom: 12,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('collab-document-cover-edit'),
                  onPressed: () =>
                      widget.onEditCover!(context, editorState, node),
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('编辑封面'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xCC1F2937),
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
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

  @override
  void dispose() {
    unawaited(_videoController?.dispose());
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
