import 'dart:math' as math;

/// AppFlowy 节点保存的正式图片投影；仅用于展示与事务，不是 WS JSON 协议。
const collabImageAttribute = 'cses_blockcraft_image';

/// 原 caption 子块的身份和文字。格式、props、meta 由 Rust 保留在原 Y.Text/Map 中。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_image.dart';
/// const caption = CollabImageCaption(id: 'caption-1', text: '图片说明');
/// ```
final class CollabImageCaption {
  /// 创建题注；[id] 是稳定的正式块 ID，[text] 是完整 Unicode 文字，可为空。
  /// 对象不持有资源；修改文字应经编辑器事务提交，不能直接操作共享 Doc。
  const CollabImageCaption({required this.id, required this.text});

  /// 正式 caption 块 ID；新增题注必须使用尚未被文档占用的 ID。
  final String id;

  /// 题注完整文字；空字符串保留空题注，不表示删除子块。
  final String text;

  /// 从节点属性 [json] 恢复强类型；id/text 缺失或类型错误抛出 TypeError。
  factory CollabImageCaption.fromJson(Map<String, dynamic> json) =>
      CollabImageCaption(id: json['id'] as String, text: json['text'] as String);

  /// 输出节点属性所需 Map，不包含原始富文本或任何凭证。
  Map<String, dynamic> toJson() => {'id': id, 'text': text};

  /// 按题注身份和完整文字计算值哈希，不修改文档。
  @override
  int get hashCode => Object.hash(id, text);

  /// 与 [other] 比较题注投影，用于检测本地事务和远端属性变化。
  @override
  bool operator ==(Object other) => other is CollabImageCaption && other.id == id && other.text == text;
}

/// 正式图片的布局与有序题注投影；图片 URL 和对齐由所属块持有。
///
/// 原始数值与显示默认值分开保存，屏幕宽度变化只影响布局，不能产生协同写入。
/// 调用方须保持 [captions] 不可变；本对象不持有网络、监听或编辑器资源。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_image.dart';
/// const image = CollabImage(widthRatio: 60, aspectRatio: 1.5);
/// final size = image.resolveSize(300); // (180, 120)，不会修改 wr/ar。
/// ```
final class CollabImage {
  /// 创建投影。[widthRatio] 为正文宽度百分比，[aspectRatio] 为宽/高；正数有效。
  /// [width]/[height] 是旧版像素尺寸；有有效 widthRatio 时优先使用比例尺寸。
  /// [rotation] 为旋转角度，null 按零度显示；[captions] 默认空，按原 children 顺序保存。
  /// 所有尺寸 null 表示原属性未设置，显示默认值为 100% 和 4:3，不自动写回文档。
  const CollabImage({
    this.widthRatio,
    this.aspectRatio,
    this.width,
    this.height,
    this.rotation,
    this.captions = const [],
  });

  /// 原 props.wr；null 保留未设置状态，显示时回退旧宽度或 100%。
  final double? widthRatio;

  /// 原 props.ar；有效正数表示宽高比，显示缺省为 4:3。
  final double? aspectRatio;

  /// 旧 props.width，单位为桌面 CSS 像素；只用于兼容，手机展示不能超出正文宽度。
  final double? width;

  /// 旧 props.height，单位为桌面 CSS 像素；缺失时根据默认比例计算。
  final double? height;

  /// 原 props.rotation，单位为度；渲染时使用，普通文字编辑不改变它。
  final double? rotation;

  /// 原图片 children 中的有序 caption 投影；与根级正文分开维护。
  final List<CollabImageCaption> captions;

  /// 读取节点属性 [json]；数值转为 double，题注集合显式恢复为不可变强类型列表。
  /// 错误属性类型抛出 TypeError；仅适用于本 Demo 的节点属性，不解析服务端消息。
  factory CollabImage.fromJson(Map<String, dynamic> json) => CollabImage(
    widthRatio: (json['wr'] as num?)?.toDouble(),
    aspectRatio: (json['ar'] as num?)?.toDouble(),
    width: (json['width'] as num?)?.toDouble(),
    height: (json['height'] as num?)?.toDouble(),
    rotation: (json['rotation'] as num?)?.toDouble(),
    captions: List.unmodifiable(
      (json['captions'] as List? ?? const []).map(
        (value) => CollabImageCaption.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    ),
  );

  /// 输出完整节点属性，显式转换题注；null 原值保留，避免显示默认值反向污染 Doc。
  Map<String, dynamic> toJson() => {
    'wr': widthRatio,
    'ar': aspectRatio,
    'width': width,
    'height': height,
    'rotation': rotation,
    'captions': captions.map((c) => c.toJson()).toList(growable: false),
  };

  /// 根据 [availableWidth]（逻辑像素）返回显示宽高，遵循比例优先、旧像素尺寸兼容规则。
  /// 宽度百分比显示限制为 0.1～100，旧尺寸按比例缩小；不会修改投影或触发网络。
  (double, double) resolveSize(double availableWidth) {
    final available = availableWidth.isFinite && availableWidth > 0 ? availableWidth : 1.0;
    final ratio = _positive(aspectRatio) ?? 4 / 3;
    final wr = _positive(widthRatio);
    final oldWidth = _positive(width);
    if (wr == null && oldWidth != null) {
      final shownWidth = math.min(oldWidth, available);
      final oldHeight = _positive(height) ?? oldWidth / (4 / 3);
      return (shownWidth, oldHeight * shownWidth / oldWidth);
    }
    final shownWidth = available * (wr ?? 100).clamp(0.1, 100) / 100;
    return (shownWidth, shownWidth / ratio);
  }

  /// [value] 为有限正数时返回原值，否则返回 null，供显示安全回退使用。
  static double? _positive(double? value) => value != null && value.isFinite && value > 0 ? value : null;

  /// 按全部布局属性和有序题注计算值哈希。
  @override
  int get hashCode => Object.hash(widthRatio, aspectRatio, width, height, rotation, Object.hashAll(captions));

  /// 与 [other] 比较完整图片投影，确保仅尺寸或题注变化也会触发远端刷新。
  @override
  bool operator ==(Object other) =>
      other is CollabImage &&
      widthRatio == other.widthRatio &&
      aspectRatio == other.aspectRatio &&
      width == other.width &&
      height == other.height &&
      rotation == other.rotation &&
      captions.length == other.captions.length &&
      List.generate(captions.length, (i) => captions[i] == other.captions[i]).every((v) => v);
}
