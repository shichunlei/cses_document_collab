import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';

/// 在借用的[state]中执行通用段落回车，供宿主自定义快捷命令委托。
///
/// 沿用段落、标题和列表的格式继承、同父容器范围替换及撤销边界；
/// Shift回车、非文字叶子、跨父容器、只读或销毁会话返回false，交还后续输入链。
/// 返回的Future在事务处理完成后结束，异常向调用方传播；不释放正文或滚动资源。
/// 宿主应先处理自己的结构边界，再调用本入口。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final enter = CharacterShortcutEvent(
///   key: 'host-paragraph-enter',
///   character: '\n',
///   handler: handleDocumentParagraphEnter,
/// );
/// final document = DocumentEditorController();
/// final view = AppFlowyEditor(
///   editorState: document.editorState,
///   characterShortcutEvents: [enter, ...standardCharacterShortcutEvents],
/// );
/// // 将 view 移出组件树后 await document.close()。
/// ```
Future<bool> handleDocumentParagraphEnter(EditorState state) =>
    handleCollabParagraphEnter(state);

/// 在借用[editorState]的[selection]处转换空文字块，或在非空文字块后插入[blockType]。
///
/// [headingLevel]只供标题使用，null沿用一级；块类型和级别受当前编辑配置约束。
/// 不拥有正文，返回true表示命令已处理；只读、销毁、不支持或目标失效返回false。
/// 正文变更和撤销记录仍须通过宿主设置的事务保护，异常向调用边界传播。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final document = DocumentEditorController();
/// await applyDocumentBlockShortcut(
///   document.editorState,
///   Selection.collapsed(Position(path: [0])),
///   TodoListBlockKeys.type,
/// );
/// await document.close();
/// ```
Future<bool> applyDocumentBlockShortcut(
  EditorState editorState,
  Selection selection,
  String blockType, {
  int? headingLevel,
}) => applyBlockShortcut(
  editorState,
  selection,
  blockType,
  headingLevel: headingLevel,
);
