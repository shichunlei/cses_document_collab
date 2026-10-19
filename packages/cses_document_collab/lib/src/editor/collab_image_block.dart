import 'dart:async';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart' show csesEmbedUrlAttribute;
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_cached_image.dart';
import 'package:cses_document_collab/src/editor/collab_image_editor.dart';
import 'package:cses_document_collab/src/editor/collab_media_block_base.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

/// 图片块的独立构建器；正式图片的选区和内容由同一块状态管理，无专属投影的离线图片沿用AppFlowy组件。
/// 不增加菜单、改变加载策略或持有编辑器。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_image_block.dart';
/// final builder = CollabImageBlockComponentBuilder();
/// // 注册到 AppFlowyEditor.blockComponentBuilders['image']。
/// ```
class CollabImageBlockComponentBuilder extends BlockComponentBuilder {
  /// [configuration]沿用原媒体的默认布局和选区配置，构建器不创建网络或原生资源。
  CollabImageBlockComponentBuilder({super.configuration = const BlockComponentConfiguration()});

  /// 保持原图片外壳校验；题注仍由专属属性携带，不把共享子树展平到正文。
  @override
  BlockComponentValidate get validate =>
      (node) => node.children.isEmpty && node.delta == null && node.attributes[csesEmbedUrlAttribute] is String;

  /// 用借用[context]创建原图片内容；缺少正式图片投影时保留原AppFlowy回退。
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    final node = context.node;
    if (node.attributes[collabImageAttribute] == null) {
      return ImageBlockComponentBuilder(configuration: configuration).build(context);
    }
    return CollabImageBlock(
      key: node.key,
      node: node,
      configuration: configuration,
      showActions: showActions(node),
      actionBuilder: (anchor, state) => actionBuilder(context, state),
      actionTrailingBuilder: (anchor, state) => actionTrailingBuilder(context, state),
    );
  }
}

/// 完整图片块，借用编辑器并持有原图片解码状态、布局和菜单。
/// 图片必须带有正式图片投影；借用的编辑器须完成样式初始化，编辑器和节点仍由页面持有。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_image_block.dart';
/// import 'package:flutter/widgets.dart';
/// import 'package:provider/provider.dart';
/// Widget imageView(Node node, EditorState editor) =>
///     Provider<EditorState>.value(value: editor, child: CollabImageBlock(key: node.key, node: node));
/// ```
class CollabImageBlock extends CollabMediaBlock {
  /// [key]控制身份复用，[node]为必填的正式图片节点。
  /// [configuration]省略时使用原媒体默认边距；编辑器从祖先Provider借用，不由块释放。
  /// [showActions]默认false，控制块级工具栏包装；[actionBuilder]与
  /// [actionTrailingBuilder]为可空的借用工具栏回调，不转移其资源所有权。
  const CollabImageBlock({
    super.key,
    required super.node,
    super.configuration = const BlockComponentConfiguration(),
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
  });

  /// 创建同时管理原选区外壳与图片解码/展示的状态，不创建视频播放器。
  @override
  createState() => _CollabImageBlockState();
}

/// 图片块统一的选区和内容状态；data URI仍在后台解码，旧源及已关闭块拒绝迟到结果。
class _CollabImageBlockState extends CollabMediaBlockState<CollabImageBlock> {
  /// 当前解码请求的地址，用于拒绝换源后的迟到结果。
  String _source = '';

  /// 当前data URI的解码结果，只由本State持有。
  Uint8List? _data;

  /// 当前data URI是否解码失败，换源时重置。
  bool _dataFailed = false;

  /// 当前事务中的资源地址；空值显示占位，blob 地址不当作手机文件路径。
  String get _url => widget.node.attributes[ImageBlockKeys.url] as String? ?? '';

  /// 在初次挂载时准备 data URI，HTTP(S) 图片由 Flutter ImageProvider 管理。
  @override
  void initState() {
    super.initState();
    unawaited(_prepareSource());
  }

  /// [oldWidget] 更新后根据保存的源字符串检测 URL 变化，兼容同一 Node 的原地属性更新。
  @override
  void didUpdateWidget(covariant CollabImageBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_source != _url) unawaited(_prepareSource());
  }

  /// 在 UI isolate 外解码当前 data URI；预期格式失败本地展示，不改写正文或反复重试。
  /// Future 包含自身异常边界；页面销毁和旧 URL 结果都不会产生迟到 setState。
  Future<void> _prepareSource() async {
    final source = _url;
    _source = source;
    _data = null;
    _dataFailed = false;
    if (!source.startsWith('data:')) return;
    try {
      final bytes = await compute(_decodeImageData, source);
      if (mounted && _source == source) setState(() => _data = bytes);
    } catch (error, stackTrace) {
      if (error is! FormatException) {
        CollabDiagnostics.report('图片数据解码失败', error: error, stackTrace: stackTrace, tag: 'DocCollab');
      }
      if (mounted && _source == source) setState(() => _dataFailed = true);
    }
  }

  /// 使用 [context] 的正文宽度解析尺寸，更多菜单集中编辑、删除和下方插入。
  /// 布局计算不写入 wr/ar 或题注；编辑及复制链接前等待菜单退场并验证当前身份及权限。
  @override
  Widget buildMedia(BuildContext context) {
    final host = collabBlockActionContext(context);
    final editor = context.read<EditorState>();
    final id = widget.node.attributes['cses_collab_block_id'] as String? ?? widget.node.id;
    final image = CollabImage.fromJson(Map<String, dynamic>.from(widget.node.attributes[collabImageAttribute] as Map));
    final align = widget.node.attributes[blockComponentAlign];
    final alignment = align == 'right'
        ? Alignment.centerRight
        : align == 'center'
        ? Alignment.center
        : Alignment.centerLeft;
    return LayoutBuilder(
      builder: (context, constraints) {
        final (width, height) = image.resolveSize(constraints.maxWidth);
        return Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: alignment,
                  child: SizedBox(
                    key: const ValueKey('collab-image-box'),
                    width: width,
                    height: height,
                    child: Transform.rotate(angle: (image.rotation ?? 0) * math.pi / 180, child: _buildImage()),
                  ),
                ),
                for (final caption in image.captions)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      caption.text,
                      key: ValueKey('collab-image-caption-${caption.id}'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
                    ),
                  ),
              ],
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                child: CollabBlockMoreButton(
                  key: ValueKey('block-more-${widget.node.attributes['cses_collab_block_id'] ?? widget.node.id}'),
                  editor: editor,
                  node: widget.node,
                  actions: [
                    if (_url.trim().isNotEmpty)
                      (
                        label: '复制链接',
                        key: ValueKey('media-copy-link-$id'),
                        run: () => copyCollabMediaLink(host, editor, widget.node),
                      ),
                    (
                      label: '编辑图片',
                      key: const ValueKey('collab-image-edit'),
                      run: () async {
                        final source = findCollabActionNode(editor, id);
                        if (source != null) {
                          await showCollabImageEditor(host, editor, source);
                        }
                      },
                    ),
                    (
                      label: image.captions.isEmpty ? '添加题注' : '编辑题注',
                      key: const ValueKey('collab-image-caption'),
                      run: () async {
                        final source = findCollabActionNode(editor, id);
                        if (source != null) {
                          await showCollabImageEditor(host, editor, source, captionOnly: true);
                        }
                      },
                    ),
                    (
                      label: '删除图片',
                      key: const ValueKey('collab-image-menu-delete'),
                      run: () async {
                        await deleteCollabImage(editor, id);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 构建当前地址的图片加载器；加载失败/空值/其他端 blob 上传均有明确占位。
  /// 位图使用CachedNetworkImage，SVG复用其文件缓存并由SvgPicture绘制。
  /// 无扩展名SVG在位图解码失败后仅检查已缓存文件，不额外重试网络。
  /// data URI在后台解码后按MIME区分SVG和位图；换源不沿用旧图。
  Widget _buildImage() {
    final uri = Uri.tryParse(_url);
    if (_url.isEmpty) return _placeholder('未设置图片');
    if (uri?.scheme == 'blob') return _placeholder('图片正在其他设备上传');
    if (_url.startsWith('data:')) {
      if (_dataFailed) return _placeholder('图片数据无法读取');
      if (_data == null) return _placeholder('图片加载中');
      if (uri?.data?.mimeType.toLowerCase() == 'image/svg+xml') {
        return SvgPicture.memory(
          _data!,
          fit: BoxFit.contain,
          placeholderBuilder: (_) => _placeholder('图片加载中'),
          errorBuilder: (_, _, _) => _placeholder('图片加载失败'),
        );
      }
      return Image.memory(_data!, fit: BoxFit.contain, errorBuilder: (_, _, _) => _placeholder('图片加载失败'));
    }
    if (uri == null || !['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      return _placeholder('暂不支持的图片来源');
    }
    return CollabCachedImage(
      key: ValueKey('collab-image-network:$_url'),
      url: _url,
      loading: _placeholder('图片加载中'),
      failure: _placeholder('图片加载失败'),
    );
  }

  /// 显示 [message] 描述的资源状态；占位不触发写入或网络重试。
  Widget _placeholder(String message) => ColoredBox(
    color: const Color(0xFFF1F5F9),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(message, textAlign: TextAlign.center),
      ),
    ),
  );
}

/// 在后台解码 [source] 的 image/* data URI，最大接受 32 MiB 的编码文本。
/// 类型、大小或 Base64 不合法时抛出 FormatException，不尝试把它当本地路径。
Uint8List _decodeImageData(String source) {
  if (source.length > 32 * 1024 * 1024) throw const FormatException('图片数据过大');
  final data = Uri.tryParse(source)?.data;
  if (data == null || !data.mimeType.startsWith('image/')) {
    throw const FormatException('不是图片数据');
  }
  return data.contentAsBytes();
}
