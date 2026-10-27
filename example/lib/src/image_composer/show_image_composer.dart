import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';

import 'image_composer_controller.dart';
import 'image_composer_page.dart';
import 'image_composer_template.dart';

/// 打开纯本地编辑与模板预览，不导出图片、不启用块锁或同步。
///
/// [context]提供导航器与主题，[initialText]为初始纯文本，默认空白。
/// [templates]为非空、ID唯一的本地模板，null使用内置渐变。
/// [editorConfig]为冻结的本地能力，null启用全部已注册块；非法配置抛出ArgumentError。
/// [services]为借用的显式业务端口，null使用空服务，不继承活动协同文档端口。
/// Future在路由完整退场且本地编辑资源释放后完成；返回不保存正文。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// import 'package:cses_mobile_collab_demo/src/image_composer/show_image_composer.dart';
/// Future<void> edit(BuildContext context) => showImageComposer(
///   context: context,
///   editorConfig: EditorConfiguration(blocks: [EditorBlock.paragraph, EditorBlock.quote]),
/// );
/// ```
Future<void> showImageComposer({
  required BuildContext context,
  String initialText = '',
  List<ImageComposerTemplate>? templates,
  EditorConfiguration? editorConfig,
  CollabHostServices? services,
}) async {
  final navigator = Navigator.of(context);
  final controller = ImageComposerController(
    initialText: initialText,
    templates: templates ?? imageComposerTemplates,
    configuration: editorConfig,
    services: services,
  );
  final route = MaterialPageRoute<void>(builder: (_) => ImageComposerPage(controller: controller));
  try {
    await navigator.push(route);
    await route.completed;
  } finally {
    await controller.close();
  }
}
