import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_block_delete.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_embed_block.dart';
import 'package:cses_mobile_collab_demo/src/ui/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';

/// A portable, full-screen collaborative editor.
///
/// Connection setup and controller ownership deliberately stay outside this
/// widget. A host application only needs to inject a [CollabController] whose
/// lifecycle is longer than this route.
class CollaborativeEditorPage extends StatefulWidget {
  const CollaborativeEditorPage({super.key, required this.collab});

  final CollabController collab;

  @override
  createState() => _CollaborativeEditorPageState();
}

class _CollaborativeEditorPageState extends State<CollaborativeEditorPage> {
  bool _isPreview = false;

  CollabController get collab => widget.collab;

  @override
  void didUpdateWidget(covariant CollaborativeEditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collab != widget.collab) {
      oldWidget.collab.editorState.editable = true;
      _isPreview = false;
      widget.collab.editorState.editable = true;
    }
  }

  @override
  void dispose() {
    collab.editorState.editable = true;
    super.dispose();
  }

  void _toggleMode() {
    final nextPreview = !_isPreview;
    final editorState = collab.editorState;
    if (nextPreview) {
      FocusManager.instance.primaryFocus?.unfocus();
      editorState.service.keyboardService?.closeKeyboard();
      editorState.selection = null;
    }
    editorState.editable = !nextPreview;
    setState(() => _isPreview = nextPreview);
  }

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
              if (!_isPreview) ...[
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
                message: _isPreview ? '进入编辑' : '进入预览',
                child: TextButton.icon(
                  key: const ValueKey('editor-mode-toggle'),
                  onPressed: _toggleMode,
                  icon: Icon(
                    _isPreview
                        ? Icons.edit_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  label: Text(_isPreview ? '编辑' : '预览'),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                _EditorConnectionBar(
                  status: collab.status,
                  documentId: collab.documentId,
                  protocolEvent: collab.lastProtocolEvent,
                ),
                if (collab.error != null)
                  _EditorErrorBanner(message: collab.error!),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: _isPreview
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

  Widget _buildEditor() {
    return IgnorePointer(
      ignoring: !collab.initialized,
      child: Opacity(
        opacity: collab.initialized ? 1 : 0.45,
        child: AppFlowyEditor(
          key: const ValueKey('collaborative-appflowy-editor'),
          editorState: collab.editorState,
          editable: !_isPreview,
          disableKeyboardService: _isPreview,
          blockComponentBuilders: _collabBlockComponentBuilders,
          // The custom Backspace command must precede AppFlowy's standard
          // handler; otherwise the standard implementation skips non-Delta
          // resource blocks and merges with an earlier text paragraph.
          commandShortcutEvents: [
            collabUrlBackedBlockBackspaceCommand,
            ...standardCommandShortcutEvents,
          ],
          shrinkWrap: false,
          editorStyle: const EditorStyle.mobile(
            padding: EdgeInsets.only(top: 8, bottom: 24),
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
  // AppFlowy already supplies the image renderer through the standard map.
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
    configuration: standardBlockComponentConfiguration.copyWith(
      padding: _listBlockPadding,
    ),
  ),
  TodoListBlockKeys.type: TodoListBlockComponentBuilder(
    configuration: standardBlockComponentConfiguration.copyWith(
      padding: _listBlockPadding,
    ),
  ),
  csesCodeBlockType: ParagraphBlockComponentBuilder(
    configuration: const BlockComponentConfiguration(
      padding: _codeBlockPadding,
      textStyle: _codeBlockTextStyle,
      placeholderText: _codeBlockPlaceholder,
    ),
  ),
};

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
  return EdgeInsets.fromLTRB(indent * 28.0, 4, 0, 4);
}

InlineSpan _collabTextSpanDecorator(
  BuildContext context,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
  TextSpan after,
) {
  final decorated = mobileTextSpanDecoratorForAttribute(
    context,
    node,
    index,
    text,
    before,
    after,
  );
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

EdgeInsets _codeBlockPadding(Node node) =>
    const EdgeInsets.symmetric(horizontal: 12, vertical: 10);

TextStyle _codeBlockTextStyle(Node node, {TextSpan? textSpan}) =>
    const TextStyle(fontFamily: 'monospace', fontSize: 15, height: 1.5);

String _codeBlockPlaceholder(Node node) => '输入代码';

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
