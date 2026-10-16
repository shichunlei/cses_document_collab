import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_image_editor.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 正式图片内容视图；外层资源块负责选区，本视图只负责布局、加载及编辑入口。
///
/// 图片 URL、尺寸或题注变化后重新读取当前 Node，不缓存旧 Image Widget。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_image_content.dart';
/// import 'package:flutter/widgets.dart';
/// Widget imageView(Node node, EditorState editorState) =>
///     CollabImageContent(node: node, editorState: editorState);
/// ```
class CollabImageContent extends StatefulWidget {
  /// 借用 [node] 和 [editorState]；调用方提供正式 collabImageAttribute 投影并负责资源释放。
  /// [key] 维持同一图片块的 Widget 身份，不用 URL 或随机值重建整篇编辑器。
  const CollabImageContent({super.key, required this.node, required this.editorState});

  /// 当前图片节点；URL、align、布局和题注由其事务属性提供。
  final Node node;

  /// 所属编辑器；只读时隐藏编辑入口，本视图不创建或销毁编辑器。
  final EditorState editorState;

  /// 创建持有 data URI 解码结果的展示状态。
  @override
  createState() => _CollabImageContentState();
}

/// data URI 在后台解码；异步结果必须仍属于当前 URL 且 State 存活才可回写。
class _CollabImageContentState extends State<CollabImageContent> {
  String _source = '';
  Uint8List? _data;
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
  void didUpdateWidget(covariant CollabImageContent oldWidget) {
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
  /// 布局计算不写入 wr/ar 或题注；编辑前等待菜单退场并验证当前身份及权限。
  @override
  Widget build(BuildContext context) {
    final host = collabBlockActionContext(context);
    final editor = widget.editorState;
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
                  editor: widget.editorState,
                  node: widget.node,
                  actions: [
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
    if (uri.path.toLowerCase().endsWith('.svg')) {
      return _svgImage(cacheOnly: false);
    }
    return CachedNetworkImage(
      key: ValueKey('collab-image-network:$_url'),
      imageUrl: _url,
      fit: BoxFit.contain,
      placeholder: (_, _) => _placeholder('图片加载中'),
      errorWidget: (_, _, _) => _svgImage(cacheOnly: true),
    );
  }

  /// 为当前源创建SVG视图。[cacheOnly]为true时仅检查位图加载器已缓存的文件；
  /// false允许缓存管理器下载。URL身份及FutureBuilder共同隔离旧请求。
  Widget _svgImage({required bool cacheOnly}) => _CachedSvgImage(
    key: ValueKey('collab-image-svg:$_url:$cacheOnly'),
    url: _url,
    cacheOnly: cacheOnly,
    loading: _placeholder('图片加载中'),
    failure: _placeholder('图片加载失败'),
  );

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

/// Reuses the image provider's borrowed global cache for SVG bytes.
/// Only this view's future is retained; the shared manager is never disposed here.
class _CachedSvgImage extends StatefulWidget {
  /// [key] controls identity; [url] is the complete cache/download address.
  /// [cacheOnly] disables downloads for raster-error fallback. [loading] and
  /// [failure] are borrowed status widgets, also used during vector parsing.
  const _CachedSvgImage({
    super.key,
    required this.url,
    required this.cacheOnly,
    required this.loading,
    required this.failure,
  });

  /// Source URL, including query parameters, used as the cache identity.
  final String url;

  /// Whether only an already cached file may be read.
  final bool cacheOnly;

  /// Loading surface borrowed from the enclosing image block.
  final Widget loading;

  /// Failure surface for unavailable, invalid or unsupported SVG data.
  final Widget failure;

  /// Creates the request state; no global resources are acquired.
  @override
  createState() => _CachedSvgImageState();
}

/// Retains one request future; FutureBuilder ignores completions from old sources.
class _CachedSvgImageState extends State<_CachedSvgImage> {
  /// Current source read; its bytes are owned by this view until it is removed.
  late Future<Uint8List?> _request;

  /// Starts the initial cache read without allocating a second cache manager.
  @override
  void initState() {
    super.initState();
    _request = _read();
  }

  /// Replaces the request when borrowed [oldWidget] had a different source or policy.
  @override
  void didUpdateWidget(covariant _CachedSvgImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.cacheOnly != widget.cacheOnly) {
      _request = _read();
    }
  }

  /// Reads the cache file asynchronously; fallback identifies SVG in a worker
  /// isolate and never fetches missing files. Missing/non-SVG cached data returns
  /// null; FutureBuilder consumes read failures. The global manager is borrowed.
  Future<Uint8List?> _read() async {
    final manager = CachedNetworkImageProvider.defaultCacheManager;
    final file = widget.cacheOnly
        ? (await manager.getFileFromCache(widget.url))?.file
        : await manager.getSingleFile(widget.url);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (!widget.cacheOnly) return bytes;
    return await compute(_looksLikeSvg, bytes) ? bytes : null;
  }

  /// Renders with borrowed [context]; unsupported files never reach the SVG parser.
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _request,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return widget.loading;
      }
      if (snapshot.hasError || snapshot.data == null) return widget.failure;
      return SvgPicture.memory(
        snapshot.data!,
        fit: BoxFit.contain,
        placeholderBuilder: (_) => widget.loading,
        errorBuilder: (_, _, _) => widget.failure,
      );
    },
  );
}

/// Recognizes an SVG root in cached [bytes]; called through compute so long XML
/// comments/metadata do not block the UI. BOM and namespace prefixes are accepted.
bool _looksLikeSvg(Uint8List bytes) =>
    RegExp(r'<(?:[A-Za-z_][\w.-]*:)?svg(?:\s|>)').hasMatch(utf8.decode(bytes, allowMalformed: true));

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
