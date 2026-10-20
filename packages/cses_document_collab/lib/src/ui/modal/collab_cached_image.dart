import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 正文图片、封面与图标共用的HTTP(S)缓存渲染；调用方验证来源并持有业务状态。
/// 位图使用CachedNetworkImage；SVG借用同一全局文件缓存，不创建或释放缓存管理器。
/// 无后缀SVG仅在位图失败后检查已有缓存，不重复下载；旧源完成不覆盖新源。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_cached_image.dart';
/// import 'package:flutter/widgets.dart';
/// const image = CollabCachedImage(
///   url: 'https://example.com/cover.png',
///   loading: SizedBox.shrink(),
///   failure: Text('图片加载失败'),
/// );
/// ```
class CollabCachedImage extends StatelessWidget {
  /// [key]控制组件身份；[url]为已验证的HTTP(S)完整地址，包含缓存键使用的查询参数。
  /// [loading]和[failure]是借用的加载/失败占位，亦用于SVG解析过程。
  /// [fit]默认contain；[alignment]默认居中，控制位图与SVG相同的裁切位置。
  /// [width]和[height]为逻辑像素，null跟随父约束；[semanticsLabel]为可选图片说明。
  const CollabCachedImage({
    super.key,
    required this.url,
    required this.loading,
    required this.failure,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.semanticsLabel,
  });

  /// 必填网络地址；完整字符串用作缓存和异步视图身份。
  final String url;

  /// 必填加载占位；不由本组件释放。
  final Widget loading;

  /// 必填失败占位；无效图片、缓存错误及SVG解析失败均使用它。
  final Widget failure;

  /// 画面适配方式，默认contain；封面可指定cover。
  final BoxFit fit;

  /// 画面裁切位置，默认居中。
  final Alignment alignment;

  /// 可选宽度，单位逻辑像素；null使用父约束。
  final double? width;

  /// 可选高度，单位逻辑像素；null使用父约束。
  final double? height;

  /// 可选的辅助功能图片说明。
  final String? semanticsLabel;

  /// 借用[context]构建按源隔离的缓存视图；SVG保持原始颜色。
  @override
  Widget build(BuildContext context) {
    final svg = Uri.parse(url).path.toLowerCase().endsWith('.svg');
    final image = svg
        ? _svg(cacheOnly: false)
        : CachedNetworkImage(
            key: ValueKey('cached-raster:$url'),
            imageUrl: url,
            width: width,
            height: height,
            fit: fit,
            alignment: alignment,
            placeholder: (_, _) => loading,
            errorWidget: (_, _, _) => _svg(cacheOnly: true),
          );
    return Semantics(label: semanticsLabel, image: true, child: image);
  }

  /// [cacheOnly]为true时仅检查位图下载器已有的文件，不发起第二次下载。
  Widget _svg({required bool cacheOnly}) => _CachedSvgImage(
    key: ValueKey('cached-svg:$url:$cacheOnly'),
    image: this,
    cacheOnly: cacheOnly,
  );
}

/// 保留一次缓存读取Future；换源通过身份与FutureBuilder隔离迟到结果。
class _CachedSvgImage extends StatefulWidget {
  /// [key]控制请求身份；[image]为借用的源和布局参数；[cacheOnly]禁止下载回退源。
  const _CachedSvgImage({
    super.key,
    required this.image,
    required this.cacheOnly,
  });

  /// 借用的源、布局与占位配置，不持有业务对象。
  final CollabCachedImage image;

  /// 为true时只读取已有缓存。
  final bool cacheOnly;

  /// 创建只持有本地读取Future的状态，不获取全局资源所有权。
  @override
  createState() => _CachedSvgImageState();
}

/// 异步读取借用缓存并解码SVG，组件退出不销毁共享缓存。
class _CachedSvgImageState extends State<_CachedSvgImage> {
  /// 当前读取Future；其字节仅由此视图保留。
  late Future<Uint8List?> _request;

  /// 启动首次读取，FutureBuilder处理失败结果。
  @override
  void initState() {
    super.initState();
    _request = _read();
  }

  /// [oldWidget]的源或读取策略变化时替换Future，布局变化无需重新下载。
  @override
  void didUpdateWidget(covariant _CachedSvgImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.url != widget.image.url ||
        oldWidget.cacheOnly != widget.cacheOnly) {
      _request = _read();
    }
  }

  /// 借用默认缓存读取文件；无后缀回退在后台识别SVG，缺失或非SVG返回null。
  /// 文件读取/下载异常交给FutureBuilder显示失败占位。
  Future<Uint8List?> _read() async {
    final manager = CachedNetworkImageProvider.defaultCacheManager;
    final file = widget.cacheOnly
        ? (await manager.getFileFromCache(widget.image.url))?.file
        : await manager.getSingleFile(widget.image.url);
    if (file == null) return null;
    final bytes = await file.readAsBytes();
    if (!widget.cacheOnly) return bytes;
    return await compute(_looksLikeSvg, bytes) ? bytes : null;
  }

  /// 借用[context]渲染当前请求，保留适配/对齐/尺寸并使用调用方占位。
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _request,
    builder: (context, snapshot) {
      final image = widget.image;
      if (snapshot.connectionState != ConnectionState.done) {
        return image.loading;
      }
      if (snapshot.hasError || snapshot.data == null) return image.failure;
      return SvgPicture.memory(
        snapshot.data!,
        fit: image.fit,
        alignment: image.alignment,
        width: image.width,
        height: image.height,
        placeholderBuilder: (_) => image.loading,
        errorBuilder: (_, _, _) => image.failure,
      );
    },
  );
}

/// 在后台识别[bytes]中的SVG根元素，接受XML头、BOM和命名空间前缀。
bool _looksLikeSvg(Uint8List bytes) => RegExp(
  r'<(?:[A-Za-z_][\w.-]*:)?svg(?:\s|>)',
).hasMatch(utf8.decode(bytes, allowMalformed: true));
