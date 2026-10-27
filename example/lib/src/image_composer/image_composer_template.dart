import 'package:flutter/material.dart';

/// 本地制图的渐变背景与白色内容卡片配置，不读取网络或宿主服务。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_mobile_collab_demo/src/image_composer/image_composer_template.dart';
/// final template = ImageComposerTemplate(
///   id: 'blue', name: '蓝色', colors: const [Colors.blue, Colors.cyan]);
/// ```
final class ImageComposerTemplate {
  /// [id] 为非空唯一标识，[name] 为选择器名称。
  /// [colors] 为1～8个渐变色，构造时复制；单色按纯色绘制。
  /// [outerPadding] 是背景边距，[innerPadding] 是正文内边距，单位为逻辑像素。
  /// [cardRadius] 是卡片圆角；边距和圆角必须有限且在0～48之间。
  /// 标识、名称或尺寸不合法时抛出ArgumentError。
  ImageComposerTemplate({
    required this.id,
    required this.name,
    required List<Color> colors,
    this.outerPadding = 14,
    this.innerPadding = 20,
    this.cardRadius = 12,
  }) : colors = List.unmodifiable(colors) {
    if (id.trim().isEmpty ||
        name.trim().isEmpty ||
        colors.isEmpty ||
        colors.length > 8 ||
        [
          outerPadding,
          innerPadding,
          cardRadius,
        ].any((v) => !v.isFinite || v < 0 || v > 48)) {
      throw ArgumentError('模板标识、颜色或尺寸无效');
    }
  }

  /// 必填模板身份，同一个选择器内不得重复。
  final String id;

  /// 必填可读名称，用于缩略图及无障碍描述。
  final String name;

  /// 已复制的不可修改色表，从左上到右下绘制。
  final List<Color> colors;

  /// 背景距白色卡片的逻辑像素，默认14。
  final double outerPadding;

  /// 卡片距正文的逻辑像素，默认20。
  final double innerPadding;

  /// 白色卡片圆角的逻辑像素，默认12。
  final double cardRadius;
}

/// 无网络资源的内置模板；模板仅改变外观，不更改正文或撤销历史。
final List<ImageComposerTemplate> imageComposerTemplates = List.unmodifiable([
  ImageComposerTemplate(
    id: 'violet',
    name: '紫光',
    colors: const [Color(0xff22c9da), Color(0xff7843e9), Color(0xffc64edd)],
  ),
  ImageComposerTemplate(
    id: 'sunset',
    name: '暖阳',
    colors: const [Color(0xffffd180), Color(0xffff8a80)],
  ),
  ImageComposerTemplate(
    id: 'ocean',
    name: '晴空',
    colors: const [Color(0xff80deea), Color(0xff5c8ee6)],
  ),
  ImageComposerTemplate(
    id: 'mint',
    name: '薄荷',
    colors: const [Color(0xffb2dfdb), Color(0xffdcedc8)],
  ),
  ImageComposerTemplate(
    id: 'plain',
    name: '简约',
    colors: const [Color(0xffe5e7eb)],
  ),
]);
