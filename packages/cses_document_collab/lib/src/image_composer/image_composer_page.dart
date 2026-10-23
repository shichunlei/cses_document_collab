import 'dart:async';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/editor/document_editor_view.dart';
import 'package:cses_document_collab/src/editor/local_editor_view.dart';
import 'package:cses_document_collab/src/image_composer/image_composer_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 借用独立本地会话的编辑/模板预览页，不提供图片导出或块锁。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// import 'package:cses_document_collab/src/image_composer/image_composer_controller.dart';
/// import 'package:cses_document_collab/src/image_composer/image_composer_page.dart';
/// final controller = ImageComposerController(initialText: '正文', templates: collabImageTemplates);
/// final page = ImageComposerPage(controller: controller);
/// // page卸载后 await controller.close()；宿主使用showCollabImageComposer。
/// ```
class ImageComposerPage extends StatefulWidget {
  /// [key]控制页面身份，[controller]由路由入口创建并在完整退场后关闭。
  const ImageComposerPage({super.key, required this.controller});

  /// 借用的本地会话，页面仅管理展示状态。
  final ImageComposerController controller;

  /// 创建串行切换与预览状态。
  @override
  State<ImageComposerPage> createState() => _ImageComposerPageState();
}

/// 持有预览借用引用；编辑和预览文档均由页面控制器释放。
class _ImageComposerPageState extends State<ImageComposerPage> {
  bool _busy = false;
  DocumentEditorController? _preview;
  Selection? _editingSelection;

  /// 借用所属路由会话。
  ImageComposerController get composer => widget.controller;

  /// 注册本地事务监听，不监听协同状态。
  @override
  void initState() {
    super.initState();
    composer.editor.addListener(_changed);
  }

  /// 注销页面监听，路由完整退场后由创建者关闭会话。
  @override
  void dispose() {
    composer.editor.removeListener(_changed);
    super.dispose();
  }

  /// 本地事务完成后更新历史按钮。
  void _changed() {
    if (mounted) setState(() {});
  }

  /// 在所属页面显示[error]，不读取全局宿主诊断服务。
  void _error(Object error) {
    if (!mounted || composer.closed) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error is StateError ? error.message.toString() : '操作失败，请重试')));
  }

  /// 结束输入后切换独立只读快照；源视图卸载后再次收起平台键盘，避免弹窗遗留输入连接。
  /// 释放须等待旧预览视图卸载，迟到结果不再操作已关闭会话。
  Future<void> _togglePreview() async {
    if (_busy || composer.closed) return;
    setState(() => _busy = true);
    try {
      final state = composer.editor.editorState;
      if (_preview == null) _editingSelection = state.selection;
      state.service.keyboardService?.closeKeyboard();
      FocusScope.of(context).unfocus();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || composer.closed) return;
      if (_preview == null) {
        state.selection = null;
        final preview = composer.prepare();
        setState(() => _preview = preview);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || composer.closed) return;
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      } else {
        setState(() => _preview = null);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || composer.closed) return;
        await composer.releasePreview();
        if (!mounted || composer.closed) return;
        state.selection = _editingSelection;
      }
    } catch (error) {
      _error(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 退出路由；关闭和资源清理由公开入口等待。
  Future<void> _back() async {
    try {
      await Navigator.of(context).maybePop();
    } catch (error) {
      _error(error);
    }
  }

  /// 使用[context]主题构建编辑和纯内容预览，模板选择不进入正文历史。
  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final template = composer.template;
    return Localizations.override(
      context: context,
      delegates: const [AppFlowyEditorLocalizations.delegate],
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const ValueKey('image-composer-back'),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const Icon(LucideIcons.chevronLeft),
            onPressed: () => unawaited(_back()),
          ),
          title: const Text('本地编辑器'),
          actions: [
            if (preview == null) ...[
              IconButton(
                key: const ValueKey('image-composer-undo'),
                tooltip: '撤销',
                onPressed: _busy ? null : composer.editor.editorState.undoManager.undo,
                icon: const Icon(LucideIcons.undo2),
              ),
              IconButton(
                key: const ValueKey('image-composer-redo'),
                tooltip: '重做',
                onPressed: _busy ? null : composer.editor.editorState.undoManager.redo,
                icon: const Icon(LucideIcons.redo2),
              ),
            ],
            TextButton(
              key: const ValueKey('image-composer-preview-toggle'),
              onPressed: _busy ? null : () => unawaited(_togglePreview()),
              child: Text(preview == null ? '预览' : '编辑'),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: math.min(600, constraints.maxWidth),
                      child: preview == null
                          ? LocalEditorView(
                              key: ObjectKey(composer.editor),
                              controller: composer.editor,
                              padding: EdgeInsets.symmetric(
                                horizontal: template.outerPadding + template.innerPadding + 12,
                              ),
                            )
                          : Container(
                              key: const ValueKey('image-composer-preview'),
                              margin: const EdgeInsets.all(12),
                              padding: EdgeInsets.all(template.outerPadding),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: template.colors.length == 1
                                      ? [template.colors.single, template.colors.single]
                                      : template.colors,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(template.cardRadius),
                                child: ColoredBox(
                                  color: Colors.white,
                                  child: DocumentEditorView(
                                    key: ObjectKey(preview),
                                    editorState: preview.editorState,
                                    preview: true,
                                    editable: false,
                                    padding: EdgeInsets.all(template.innerPadding),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              if (MediaQuery.viewInsetsOf(context).bottom == 0)
                SizedBox(
                  height: 72,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    scrollDirection: Axis.horizontal,
                    itemCount: composer.templates.length,
                    itemBuilder: (context, index) {
                      final item = composer.templates[index];
                      return Semantics(
                        selected: composer.selected == index,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: OutlinedButton(
                            key: ValueKey('image-composer-template-${item.id}'),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: composer.selected == index ? const Color(0xff6b5de6) : Colors.grey.shade300,
                                width: 2,
                              ),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.all(6),
                            ),
                            onPressed: _busy ? null : () => setState(() => composer.selectTemplate(index)),
                            child: Container(
                              width: 58,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: item.colors.length == 1
                                      ? [item.colors.single, item.colors.single]
                                      : item.colors,
                                ),
                              ),
                              child: ColoredBox(
                                color: Colors.white,
                                child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Text(
                                    item.name,
                                    style: const TextStyle(fontSize: 12, color: Color(0xff1f2937)),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
