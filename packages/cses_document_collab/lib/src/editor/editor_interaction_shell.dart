import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_mobile_selection_menu.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:flutter/widgets.dart';

/// 为宿主自定义正文复用移动划词菜单和键盘快捷栏，不接管正文布局或业务模型。
///
/// 所有编辑与滚动资源均为借用；调用方先移除本组件，再释放滚动和正文会话。
/// 预览时传入 `enabled: false`，并由正文自身关闭输入和选区服务。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final document = DocumentEditorController();
/// final scroll = EditorScrollController(editorState: document.editorState);
/// final view = EditorInteractionShell(
///   editorState: document.editorState,
///   scrollController: scroll,
///   child: AppFlowyEditor(
///     editorState: document.editorState,
///     editorScrollController: scroll,
///   ),
/// );
/// // 将 view 移出组件树后：
/// // scroll.dispose();
/// // await document.close();
/// ```
class EditorInteractionShell extends StatelessWidget {
  /// [key]控制组件身份与状态复用；[editorState]和[scrollController]均由调用方拥有。
  /// [child]必须使用同一正文和滚动控制器；[enabled]默认true，false时直接显示正文。
  const EditorInteractionShell({
    super.key,
    required this.editorState,
    required this.scrollController,
    required this.child,
    this.enabled = true,
  });

  /// 借用的正文会话；命令使用其能力配置、选区和当前编辑权限。
  final EditorState editorState;

  /// 借用的正文滚动控制器，必须属于[editorState]，不由本组件释放。
  final EditorScrollController scrollController;

  /// 宿主提供的正文；渲染器、样式和业务快捷命令仍由宿主配置。
  final Widget child;

  /// 是否挂载通用编辑交互，默认true；false不改变子组件或正文状态。
  final bool enabled;

  /// 在[context]组合既有菜单与快捷栏；禁用时不创建相应监听和键盘拦截器。
  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return EditorShortcutToolbar(
      editorState: editorState,
      child: CollabMobileSelectionMenu(
        editorState: editorState,
        scrollController: scrollController,
        child: child,
      ),
    );
  }
}
