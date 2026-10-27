import 'dart:convert';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:appflowy_editor/appflowy_editor.dart';

import 'image_composer_template.dart';

/// 单个离线页面拥有的编辑与预览会话，不创建协同、锁服务或图片编码任务。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/image_composer/image_composer_template.dart';
/// import 'package:cses_mobile_collab_demo/src/image_composer/image_composer_controller.dart';
/// final controller = ImageComposerController(initialText: '正文', templates: imageComposerTemplates);
/// final preview = controller.prepare();
/// // 视图移除后关闭所有本地会话。
/// await controller.close();
/// ```
final class ImageComposerController {
  /// [initialText]为初始纯文本，[templates]为非空、ID唯一的本地模板。
  /// [services]借用显式业务端口，null使用空服务，关闭时不释放宿主资源。
  /// [configuration]为空使用默认本地能力；验证失败不创建正文资源。
  /// 模板列表为空或ID重复时抛出ArgumentError。
  ImageComposerController({
    required String initialText,
    required List<ImageComposerTemplate> templates,
    EditorConfiguration? configuration,
    CollabHostServices? services,
  }) : templates = List.unmodifiable(templates) {
    if (templates.isEmpty || templates.map((t) => t.id).toSet().length != templates.length) {
      throw ArgumentError('模板列表无效');
    }
    editor = LocalEditorController(initialText: initialText, configuration: configuration, services: services);
  }

  /// 会话创建并释放的本地正文，不占用原生文档。
  late final LocalEditorController editor;

  /// 不可修改的模板列表。
  final List<ImageComposerTemplate> templates;
  int _selected = 0;
  bool _closed = false;
  DocumentEditorController? _preview;
  Future<void>? _closing;

  /// 当前模板索引，不进入正文历史。
  int get selected => _selected;

  /// 当前模板外观。
  ImageComposerTemplate get template => templates[_selected];

  /// 是否已开始关闭，迟到回调须失效。
  bool get closed => _closed;

  /// 切换到[index]模板，不改变正文或预览快照。
  /// 会话已关闭时抛出StateError；[index]不在模板列表范围内时抛出RangeError。
  void selectTemplate(int index) {
    if (_closed) throw StateError('本地编辑器已关闭');
    if (index < 0 || index >= templates.length) throw RangeError.index(index, templates);
    _selected = index;
  }

  /// 从正文创建独立预览快照；首次创建后复用，离开预览时由releasePreview释放。
  /// 返回值由本控制器拥有，视图只借用；无光标、选区、协同或块锁服务。
  /// 会话已关闭时抛出StateError，不再创建预览资源。
  DocumentEditorController prepare() {
    if (_closed) throw StateError('本地编辑器已关闭');
    return _preview ??= DocumentEditorController(
      document: Document.fromJson(jsonDecode(jsonEncode(editor.editorState.document.toJson())) as Map<String, dynamic>),
      commandContext: EditorCommandContext(
        configuration: editor.configuration,
        localOnly: true,
        services: editor.commandContext.services,
      ),
    )..editorState.editable = false;
  }

  /// 预览视图卸载后释放快照，重复调用安全；不释放可编辑正文。
  Future<void> releasePreview() async {
    final preview = _preview;
    _preview = null;
    await preview?.close();
  }

  /// 在所有视图卸载后释放预览和正文；重复调用共享关闭结果。
  Future<void> close() => _closing ??= _close();

  /// 标记关闭并按预览、正文顺序释放自有内存资源。
  Future<void> _close() async {
    _closed = true;
    await releasePreview();
    await editor.close();
  }
}
