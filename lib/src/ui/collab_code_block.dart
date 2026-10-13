import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_common/observability/api/log.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_code.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_code_languages.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_code_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:val_highlight/languages/all.dart';
import 'package:val_highlight/val_highlight.dart';

/// Keeps AppFlowy's selectable text/IME delegate inside the desktop code shell.
class CollabCodeBlockComponentBuilder extends BlockComponentBuilder {
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta != null;

  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) =>
      _CodeBlock(
        node: blockComponentContext.node,
        key: blockComponentContext.node.key,
        configuration: configuration,
      );
}

class _CodeBlock extends BlockComponentStatefulWidget {
  const _CodeBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock>
    with SelectableMixin, DefaultSelectableMixin {
  @override
  final forwardKey = GlobalKey(debugLabel: 'code-rich-text');
  @override
  final blockComponentKey = GlobalKey(debugLabel: 'code-block');
  @override
  GlobalKey get containerKey => widget.node.key;

  late final _editor = context.read<EditorState>();
  Timer? _copiedTimer;
  bool _copied = false;
  bool? _previewCollapsed;
  String? _highlightedText;
  String? _highlightedLanguage;
  TextSpan? _highlightedSpan;
  static final _languages = allLanguagesRegistry();
  static const _codeStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    height: 1.8,
    color: Color(0xFF24292E),
    fontWeight: FontWeight.w400,
  );
  static const _headerStyle = TextStyle(
    fontSize: 12,
    height: 1.3,
    color: Color(0xFF607D9B),
    fontWeight: FontWeight.w400,
  );

  CollabCode get _metadata {
    return CollabCode.fromAttributes(widget.node.attributes);
  }

  String? get _blockId =>
      widget.node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute]
          as String?;

  Future<void> _rename(BuildContext anchor) async {
    final id = _blockId;
    if (!_editor.editable || id == null) return;
    final name = await showCodeNameEditor(anchor, _metadata.name);
    if (name == null || !mounted) return;
    await changeCollabCodeProperty(
      _editor,
      id,
      'blockName',
      name.isEmpty ? null : name,
    );
  }

  Future<void> _chooseLanguage(BuildContext anchor) async {
    final id = _blockId;
    if (!_editor.editable || id == null) return;
    final language = await showCodeLanguagePicker(anchor, _metadata.language);
    if (language == null || !mounted) return;
    await changeCollabCodeProperty(_editor, id, 'lang', language);
  }

  Future<void> _toggleCollapse(BuildContext _) async {
    if (!_editor.editable) {
      setState(
        () => _previewCollapsed = !(_previewCollapsed ?? _metadata.collapsed),
      );
      return;
    }
    final id = _blockId;
    if (id != null) {
      await changeCollabCodeProperty(
        _editor,
        id,
        'collapse',
        _metadata.collapsed ? null : true,
      );
    }
  }

  void _clearHiddenSelection() {
    if (!mounted || _editor.isDisposed) return;
    if (!(_previewCollapsed ?? _metadata.collapsed)) return;
    final selection = _editor.selection;
    final path = widget.node.path;
    if (selection == null ||
        path.isEmpty ||
        selection.start.path.isEmpty ||
        selection.end.path.isEmpty) {
      return;
    }
    if (path.inSelection(selection)) {
      _editor.selection = null;
      _editor.service.keyboardService?.closeKeyboard();
    }
  }

  Widget _headerControl({
    required String key,
    required Widget child,
    Future<void> Function(BuildContext)? onTap,
    String? label,
    EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
  }) => Builder(
    builder: (anchor) => Semantics(
      button: onTap != null,
      label: label,
      child: InkWell(
        key: ValueKey(key),
        borderRadius: BorderRadius.circular(4),
        onTap: onTap == null
            ? null
            : () async {
                try {
                  await onTap(anchor);
                } catch (error, stackTrace) {
                  Log.e(
                    '修改代码块失败',
                    error: error,
                    stackTrace: stackTrace,
                    tag: 'DocCollabDemo',
                  );
                  if (mounted) {
                    ScaffoldMessenger.maybeOf(
                      context,
                    )?.showSnackBar(const SnackBar(content: Text('修改失败，请重试')));
                  }
                }
              },
        child: Padding(padding: padding, child: child),
      ),
    ),
  );

  /// Syntax colors only decorate spans; source text and Delta stay untouched.
  TextSpan _highlight(TextSpan original) {
    final source = original.toPlainText();
    final language = _metadata.language;
    if (_highlightedText == source && _highlightedLanguage == language) {
      return _highlightedSpan!;
    }
    final alias = collabCodeLanguages[language];
    final grammar = alias == null
        ? _languages.lookup(language.toLowerCase())
        : _languages.resolve(alias);
    final tokens = grammar == null || source.length > 100000
        ? null
        : const Highlighter().highlight(source, language: grammar).tokens;
    final span = TextSpan(
      style: _codeStyle,
      children: tokens == null
          ? [TextSpan(text: source)]
          : [
              for (final token in tokens)
                TextSpan(
                  text: token.text,
                  style: TextStyle(color: _tokenColor(token.scope)),
                ),
            ],
    );
    _highlightedText = source;
    _highlightedLanguage = language;
    _highlightedSpan = span;
    return span;
  }

  static Color _tokenColor(String? scope) => switch (scope?.split('.').first) {
    'keyword' || 'operator' => const Color(0xFFD73A49),
    'string' || 'regexp' => const Color(0xFF032F62),
    'number' || 'literal' || 'type' => const Color(0xFF005CC5),
    'function' => const Color(0xFF6F42C1),
    'comment' => const Color(0xFF6A737D),
    'meta' => const Color(0xFFB31D28),
    _ => const Color(0xFF24292E),
  };

  Future<void> _copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: widget.node.delta?.toPlainText() ?? ''),
      );
      if (!mounted) return;
      _copiedTimer?.cancel();
      setState(() => _copied = true);
      _copiedTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (error, stackTrace) {
      Log.e(
        '复制代码失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollabDemo',
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
      }
    }
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metadata = _metadata;
    if (_editor.editable) _previewCollapsed = null;
    final collapsed = _previewCollapsed ?? metadata.collapsed;
    if (collapsed) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _clearHiddenSelection(),
      );
    }
    final style = _editor.editorStyle;
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        key: blockComponentKey,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE1E4E8)),
          borderRadius: BorderRadius.circular(4),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeFocus(
              child: Material(
                color: const Color(0xFFF6F8FA),
                child: Container(
                  key: const ValueKey('collab-code-header'),
                  decoration: BoxDecoration(
                    border: collapsed
                        ? null
                        : const Border(
                            bottom: BorderSide(color: Color(0xFFE1E4E8)),
                          ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      _headerControl(
                        key: 'collab-code-collapse',
                        label: collapsed ? '展开代码块' : '收起代码块',
                        onTap: _toggleCollapse,
                        child: Icon(
                          collapsed ? Icons.chevron_right : Icons.expand_more,
                          size: 16,
                          color: _headerStyle.color,
                        ),
                      ),
                      Expanded(
                        child: _headerControl(
                          key: 'collab-code-name',
                          onTap: _editor.editable ? _rename : null,
                          child: Text(
                            metadata.name.trim().isEmpty
                                ? '代码块'
                                : metadata.name.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _headerStyle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _headerControl(
                        key: 'collab-code-language',
                        onTap: _editor.editable ? _chooseLanguage : null,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 64),
                              child: Text(
                                metadata.language == 'PlainText'
                                    ? '纯文本'
                                    : metadata.language,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _headerStyle,
                              ),
                            ),
                            if (_editor.editable) ...[
                              const SizedBox(width: 2),
                              Icon(
                                Icons.expand_more,
                                size: 13,
                                color: _headerStyle.color,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      Semantics(
                        button: true,
                        label: _copied ? '代码已复制' : '复制代码',
                        child: InkWell(
                          key: const ValueKey('collab-code-copy'),
                          onTap: _copy,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 9,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _copied ? Icons.check : Icons.copy_outlined,
                                  size: 13,
                                  color: _headerStyle.color,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _copied ? '已复制' : '复制',
                                  style: _headerStyle,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Offstage(
              offstage: collapsed,
              child: Container(
                constraints: const BoxConstraints(minHeight: 60),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 16,
                ),
                child: AppFlowyRichText(
                  key: forwardKey,
                  node: widget.node,
                  editorState: _editor,
                  delegate: this,
                  textAlign: TextAlign.left,
                  textDirection: TextDirection.ltr,
                  placeholderText: '输入代码',
                  textSpanDecorator: _highlight,
                  placeholderTextSpanDecorator: (span) => span.updateTextStyle(
                    _codeStyle.copyWith(color: const Color(0xFF9CA3AF)),
                  ),
                  cursorColor: style.cursorColor,
                  selectionColor: style.selectionColor,
                  cursorWidth: style.cursorWidth,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return BlockSelectionContainer(
      node: widget.node,
      delegate: this,
      listenable: _editor.selectionNotifier,
      remoteSelection: _editor.remoteSelections,
      blockColor: style.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      child: child,
    );
  }
}
