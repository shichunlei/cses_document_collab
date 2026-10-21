import 'package:cses_document_collab/src/editor/document_editor_view.dart';
import 'package:cses_document_collab/src/editor/local_editor_controller.dart';
import 'package:flutter/material.dart';

/// 制图会话的正文装配，复用原文档的输入、工具栏和划词菜单。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/editor/local_editor_controller.dart';
/// import 'package:cses_document_collab/src/editor/local_editor_view.dart';
/// final controller = LocalEditorController();
/// final view = LocalEditorView(controller: controller, padding: const EdgeInsets.all(24));
/// // view卸载后 await controller.close()。
/// ```
class LocalEditorView extends StatelessWidget {
  /// [key]控制身份，[controller]由外部持有和释放，[padding]为正文逻辑像素留白。
  const LocalEditorView({
    super.key,
    required this.controller,
    required this.padding,
  });

  /// 必填的借用制图会话，不创建同步资源。
  final LocalEditorController controller;

  /// 正文逻辑像素留白，与模板渲染保持一致。
  final EdgeInsets padding;

  /// 用[context]的主题显示共用编辑器，不接入任何协同服务。
  @override
  Widget build(BuildContext context) => DocumentEditorView(
    editorState: controller.editorState,
    padding: padding,
    editorKey: const ValueKey('image-composer-editor'),
  );
}
