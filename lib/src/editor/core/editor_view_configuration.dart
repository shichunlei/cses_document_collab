import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/editor_keyboard_action.dart';
import 'package:flutter/widgets.dart';

/// 将视图新建的[builders]调整为宿主所需的排版及结构渲染器。
/// 返回映射交给视图使用；不得释放借用的编辑会话或保留跨文档共享的可变builder。
typedef EditorBlockBuildersConfiguration =
    Map<String, BlockComponentBuilder> Function(Map<String, BlockComponentBuilder> builders);

/// 按[context]的屏宽、字号等展示信息调整共用[style]，不修改正文或编辑权限。
typedef EditorStyleConfiguration = EditorStyle Function(BuildContext context, EditorStyle style);

/// 共用编辑视图的宿主展示与业务扩展配置；本地和协同使用同一装配及命令链。
/// 功能能力由EditorConfiguration控制，正文、存储与协同资源仍归外部会话。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final controller = DocumentEditorController();
/// final view = DocumentEditorView(
///   editorState: controller.editorState,
///   configuration: EditorViewConfiguration(
///     style: (context, style) => style.copyWith(cursorColor: Colors.brown),
///   ),
/// );
/// // 将view移出组件树后 await controller.close()。
/// ```
final class EditorViewConfiguration {
  /// [blockBuilders]可调整视图私有builder或增加宿主结构块，null沿用统一默认值。
  /// [style]只调整展示，null沿用默认排版；[characterShortcuts]为先于通用输入处理的业务扩展。
  /// [keyboardActions]按顺序接在内建菜单后，不替换编辑器命令。
  /// 集合在构造时冻结；所有回调及其业务依赖均由调用方持有。
  factory EditorViewConfiguration({
    EditorBlockBuildersConfiguration? blockBuilders,
    EditorStyleConfiguration? style,
    Iterable<CharacterShortcutEvent> characterShortcuts = const [],
    Iterable<EditorKeyboardAction> keyboardActions = const [],
  }) => EditorViewConfiguration._(
    blockBuilders: blockBuilders,
    style: style,
    characterShortcuts: List.unmodifiable(characterShortcuts),
    keyboardActions: List.unmodifiable(keyboardActions),
  );

  /// 保存借用的[blockBuilders]/[style]回调和已冻结的[characterShortcuts]/[keyboardActions]。
  const EditorViewConfiguration._({
    this.blockBuilders,
    this.style,
    this.characterShortcuts = const [],
    this.keyboardActions = const [],
  });

  /// 所有编辑模式共用的空扩展配置，不创建正文或网络资源。
  static const standard = EditorViewConfiguration._();

  /// 宿主渲染扩展；每次视图配置变化时接收新建的私有builder，不在包内定义业务块。
  final EditorBlockBuildersConfiguration? blockBuilders;

  /// 展示样式回调，每次构建读取当前屏宽/系统字号，不拥有编辑会话。
  final EditorStyleConfiguration? style;

  /// 先执行的宿主业务字符事件；通用快捷键和能力过滤始终由共用编辑视图维护。
  final List<CharacterShortcutEvent> characterShortcuts;

  /// 宿主菜单动作的不可变副本，生命周期及权限由调用方和通用工具栏共同校验。
  final List<EditorKeyboardAction> keyboardActions;
}
