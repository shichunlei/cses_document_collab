import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_block_colors.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_block_delete.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_code_block.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_callout_block.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_block_colors.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_embed_block.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_list_editing.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_ordered_marker.dart';
import 'package:cses_mobile_collab_demo/src/ui/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';

/// A portable, full-screen collaborative editor.
///
/// Connection setup and controller ownership deliberately stay outside this
/// widget. A host application only needs to inject a [CollabController] whose
/// lifecycle is longer than this route.
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
/// import 'package:cses_mobile_collab_demo/src/ui/collaborative_editor_page.dart';
/// final controller = CollabController(); // 宿主负责 initialize/configureCses 和 dispose。
/// final page = CollaborativeEditorPage(collab: controller);
/// ```
class CollaborativeEditorPage extends StatefulWidget {
  /// 借用 [collab] 展示文档与能力，不创建或关闭其协同会话。
  const CollaborativeEditorPage({super.key, required this.collab});

  /// 宿主持有的协同控制器；未知内容和锁等只读约束由该控制器提供。
  final CollabController collab;

  /// 创建页面展示状态及能力监听；释放时只归还编辑模式控制权。
  @override
  createState() => _CollaborativeEditorPageState();
}

/// 页面持有用户预览选择，并与 Rust 模型能力共同决定编辑器是否允许修改。
class _CollaborativeEditorPageState extends State<CollaborativeEditorPage> {
  bool _isPreview = false;

  /// 当前借用的文档控制器，不拥有其资源。
  CollabController get collab => widget.collab;

  /// 用户预览和模型只读约束任意一个生效时都使用只读展示。
  bool get _previewOnly => _isPreview || !collab.canEdit;

  /// 注册能力监听，使远端锁定或未知块到达后立即关闭本地输入。
  @override
  void initState() {
    super.initState();
    collab.addListener(_syncEditorMode);
    _syncEditorMode();
  }

  /// 根据控制器的当前能力同步输入状态；不连接网络或更改正文。
  void _syncEditorMode() {
    collab.editorState.editable = !_previewOnly;
    if (_previewOnly) {
      collab.editorState.service.keyboardService?.closeKeyboard();
    }
  }

  /// [oldWidget] 的控制器被替换时解绑旧监听，再绑定新实例，避免借用对象泄漏。
  @override
  void didUpdateWidget(covariant CollaborativeEditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collab != widget.collab) {
      oldWidget.collab.removeListener(_syncEditorMode);
      oldWidget.collab.editorState.editable = oldWidget.collab.canEdit;
      _isPreview = false;
      collab.addListener(_syncEditorMode);
      _syncEditorMode();
    }
  }

  /// 注销页面监听，并恢复宿主能力约束下的模式；不释放借用控制器。
  @override
  void dispose() {
    collab.removeListener(_syncEditorMode);
    collab.editorState.editable = collab.canEdit;
    super.dispose();
  }

  /// 切换用户预览选择；Rust 模型只读时拒绝进入编辑，预览会关闭键盘并清除选区。
  void _toggleMode() {
    if (!collab.canEdit) return;
    final nextPreview = !_isPreview;
    final editorState = collab.editorState;
    if (nextPreview) {
      FocusManager.instance.primaryFocus?.unfocus();
      editorState.service.keyboardService?.closeKeyboard();
      editorState.selection = null;
    }
    setState(() => _isPreview = nextPreview);
    _syncEditorMode();
  }

  /// 使用 [context] 渲染当前模式和能力；网络和监听由控制器及页面生命周期管理。
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: collab,
      builder: (context, _) {
        return Scaffold(
          key: const ValueKey('collaborative-editor-page'),
          backgroundColor: Colors.white,
          appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            title: const Text('协同文档'),
            actions: [
              if (!_previewOnly) ...[
                IconButton(
                  key: const ValueKey('editor-undo'),
                  tooltip: '撤销',
                  onPressed: collab.editorState.undoManager.undo,
                  icon: const Icon(Icons.undo),
                ),
                IconButton(
                  key: const ValueKey('editor-redo'),
                  tooltip: '重做',
                  onPressed: collab.editorState.undoManager.redo,
                  icon: const Icon(Icons.redo),
                ),
              ],
              Tooltip(
                message: _previewOnly ? '进入编辑' : '进入预览',
                child: TextButton.icon(
                  key: const ValueKey('editor-mode-toggle'),
                  onPressed: collab.canEdit ? _toggleMode : null,
                  icon: Icon(
                    _previewOnly
                        ? Icons.edit_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  label: Text(_previewOnly ? '编辑' : '预览'),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            // Use the system bottom inset once. It becomes zero above the
            // keyboard so the toolbar stays flush with the keyboard edge.
            child: Column(
              children: [
                _EditorConnectionBar(
                  status: collab.status,
                  documentId: collab.documentId,
                  protocolEvent: collab.lastProtocolEvent,
                ),
                if (collab.error != null)
                  _EditorErrorBanner(message: collab.error!),
                if (collab.readOnlyReason != null)
                  _EditorErrorBanner(message: '只读：${collab.readOnlyReason}'),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Padding(
                        // AppFlowy's editorStyle.padding is per block. Keep
                        // page spacing here and bottom spacing in SafeArea.
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        child: _previewOnly
                            ? _buildEditor()
                            : EditorShortcutToolbar(
                                editorState: collab.editorState,
                                child: _buildEditor(),
                              ),
                      ),
                      if (!collab.initialized)
                        const Align(
                          alignment: Alignment.topCenter,
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text('正在从 Rust/Yrs 加载本地文档……'),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 构建原生编辑器，输入遵守用户模式与模型能力；有序/无序/Todo 列表 Enter 在标准快捷键
  /// 之前处理扁平 depth；行首退格先退级再交给标题/媒体边界处理。软键盘通过工具栏注册
  /// 同规则拦截器，硬件命令在下方优先派发，共用事务及现有协同发布链路。
  Widget _buildEditor() {
    return IgnorePointer(
      ignoring: !collab.initialized,
      child: Opacity(
        opacity: collab.initialized ? 1 : 0.45,
        child: AppFlowyEditor(
          key: const ValueKey('collaborative-appflowy-editor'),
          editorState: collab.editorState,
          editable: !_previewOnly,
          disableKeyboardService: _previewOnly,
          blockComponentBuilders: _collabBlockComponentBuilders,
          characterShortcutEvents: [
            collabListEnter,
            ...standardCharacterShortcutEvents,
          ],
          // 列表行首先逐级退级；非列表再保护标题/删除前置媒体，最后交标准退格。
          // 不能先让标准命令合并正文，或在退级前删除列表旁的图片/视频。
          commandShortcutEvents: [
            collabBlockBackspaceCommand,
            ...standardCommandShortcutEvents,
          ],
          shrinkWrap: false,
          editorStyle: const EditorStyle.mobile(
            padding: EdgeInsets.zero,
            cursorColor: Color(0xFF5B5BD6),
            dragHandleColor: Color(0xFF5B5BD6),
            selectionColor: Color(0x335B5BD6),
            textSpanDecorator: _collabTextSpanDecorator,
          ),
        ),
      ),
    );
  }
}

final Map<String, BlockComponentBuilder> _collabBlockComponentBuilders = {
  ...standardBlockComponentBuilderMap,
  QuoteBlockKeys.type: QuoteBlockComponentBuilder(
    iconBuilder: buildCollabQuoteBorder,
  ),
  ParagraphBlockKeys.type: ParagraphBlockComponentBuilder(
    configuration: standardBlockComponentBuilderMap[ParagraphBlockKeys.type]!
        .configuration
        .copyWith(padding: _paragraphBlockPadding),
  ),
  // 正式图片复用资源块选区外壳并展示尺寸/题注；离线图片仍使用 AppFlowy 原组件。
  ImageBlockKeys.type: CollabEmbedBlockComponentBuilder(
    kind: CollabEmbedKind.image,
  ),
  // Links and videos remain first-class selectable editor blocks by providing
  // custom renderers whose URL attributes are synchronized through Rust/Yrs.
  csesLinkBlockType: CollabEmbedBlockComponentBuilder(
    kind: CollabEmbedKind.link,
  ),
  csesVideoBlockType: CollabEmbedBlockComponentBuilder(
    kind: CollabEmbedKind.video,
  ),
  // The cover is a non-text URL block. It remains selectable with AppFlowy's
  // block selection system, while the explicit callback opens a URL editor
  // only in edit mode; preview mode renders the image without edit controls.
  csesDocumentCoverBlockType: CollabEmbedBlockComponentBuilder(
    kind: CollabEmbedKind.cover,
    configuration: const BlockComponentConfiguration(
      padding: _documentCoverPadding,
    ),
    onEditCover: (context, editorState, node) {
      unawaited(showEditorDocumentCoverDialog(context, editorState, node));
    },
  ),
  // The document title intentionally reuses AppFlowy's paragraph component so
  // mobile IME, selection and collaborative Delta edits behave exactly like
  // body text. Only presentation and structural conversion rules differ.
  csesDocumentTitleBlockType: ParagraphBlockComponentBuilder(
    configuration: const BlockComponentConfiguration(
      padding: _documentTitlePadding,
      textStyle: _documentTitleTextStyle,
      placeholderText: _documentTitlePlaceholder,
      placeholderTextStyle: _documentTitlePlaceholderStyle,
    ),
  ),
  BulletedListBlockKeys.type: BulletedListBlockComponentBuilder(
    configuration: standardBlockComponentConfiguration.copyWith(
      padding: _listBlockPadding,
    ),
  ),
  NumberedListBlockKeys.type: NumberedListBlockComponentBuilder(
    iconBuilder: buildCollabOrderedMarker,
    configuration: standardBlockComponentConfiguration.copyWith(
      padding: _listBlockPadding,
    ),
  ),
  TodoListBlockKeys.type: TodoListBlockComponentBuilder(
    configuration: standardBlockComponentConfiguration.copyWith(
      padding: _listBlockPadding,
    ),
  ),
  csesCodeBlockType: CollabCodeBlockComponentBuilder(),
  csesCalloutBlockType: CollabCalloutBlockComponentBuilder(),
};

/// Reduces the extra gap between body paragraphs while preserving line height.
EdgeInsets _paragraphBlockPadding(Node node) =>
    const EdgeInsets.symmetric(vertical: 2);

/// Keeps the wide cover visually separated from the editor title and body.
EdgeInsets _documentCoverPadding(Node node) =>
    const EdgeInsets.only(top: 4, bottom: 14);

/// Gives the large editable title the compact spacing used by mobile docs.
EdgeInsets _documentTitlePadding(Node node) =>
    const EdgeInsets.only(top: 8, bottom: 20);

/// Placeholder used if a user removes every title character.
String _documentTitlePlaceholder(Node node) => '未命名文档';

/// Dedicated title typography; it is not a heading level and cannot be
/// converted by the block-style menu, preserving the fixed header invariant.
TextStyle _documentTitleTextStyle(Node node, {TextSpan? textSpan}) =>
    const TextStyle(
      color: Color(0xFF111827),
      fontSize: 38,
      fontWeight: FontWeight.w700,
      height: 1.18,
      letterSpacing: -0.8,
    );

/// Mirrors the title geometry while visually distinguishing empty content.
TextStyle _documentTitlePlaceholderStyle(Node node, {TextSpan? textSpan}) =>
    _documentTitleTextStyle(
      node,
      textSpan: textSpan,
    ).copyWith(color: const Color(0xFF9CA3AF));

EdgeInsets _listBlockPadding(Node node) {
  final value = node.attributes[csesBlockIndentAttribute];
  final indent = value is int ? value.clamp(0, 6) : 0;
  return EdgeInsets.fromLTRB(indent * 28.0, 2, 0, 2);
}

InlineSpan _collabTextSpanDecorator(
  BuildContext context,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
  TextSpan after,
) {
  var decorated = mobileTextSpanDecoratorForAttribute(
    context,
    node,
    index,
    text,
    before,
    after,
  );
  // Container color is inherited only when the text has no explicit foreground.
  if (text.attributes?[AppFlowyRichTextKeys.textColor] == null) {
    Node? ancestor = node.parent;
    while (ancestor != null) {
      if (ancestor.type == csesCalloutBlockType) {
        final color = parseCollabBlockColor(
          ancestor.attributes[csesBlockTextColorAttribute] as String?,
        );
        if (color != null) {
          decorated = TextSpan(
            text: decorated.text,
            children: decorated.children,
            style: (decorated.style ?? const TextStyle()).copyWith(
              color: color,
            ),
            recognizer: decorated.recognizer,
            mouseCursor: decorated.mouseCursor,
          );
          break;
        }
      }
      ancestor = ancestor.parent;
    }
  }
  final attributes = text.attributes;
  final superscript = attributes?[csesSuperscriptAttribute] == true;
  final subscript = attributes?[csesSubscriptAttribute] == true;
  if (!superscript && !subscript) {
    return decorated;
  }
  return TextSpan(
    text: decorated.text,
    children: decorated.children,
    style: (decorated.style ?? const TextStyle()).copyWith(
      fontFeatures: [
        if (superscript) const FontFeature.superscripts(),
        if (subscript) const FontFeature.subscripts(),
      ],
    ),
    recognizer: decorated.recognizer,
    mouseCursor: decorated.mouseCursor,
    onEnter: decorated.onEnter,
    onExit: decorated.onExit,
    semanticsLabel: decorated.semanticsLabel,
    semanticsIdentifier: decorated.semanticsIdentifier,
    locale: decorated.locale,
    spellOut: decorated.spellOut,
  );
}

class _EditorConnectionBar extends StatelessWidget {
  const _EditorConnectionBar({
    required this.status,
    required this.documentId,
    required this.protocolEvent,
  });

  final ConnectionStatus status;
  final String documentId;
  final String protocolEvent;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ConnectionStatus.starting => ('初始化', Colors.blueGrey),
      ConnectionStatus.connecting => ('连接中', Colors.orange),
      ConnectionStatus.online => ('在线', Colors.green),
      ConnectionStatus.offline => ('离线可编辑', Colors.blueGrey),
      ConnectionStatus.error => ('异常', Colors.red),
    };
    return Container(
      key: const ValueKey('editor-connection-bar'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        border: const Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 9, color: color),
          const SizedBox(width: 7),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$documentId · $protocolEvent',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorErrorBanner extends StatelessWidget {
  const _EditorErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
      ),
    );
  }
}
