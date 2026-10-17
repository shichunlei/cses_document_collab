import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_card_frame.dart';
import 'package:cses_document_collab/src/editor/collab_code_menu.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:cses_document_collab/src/model/collab_code_languages.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:val_highlight/languages/all.dart';
import 'package:val_highlight/val_highlight.dart';

/// 在统一卡片内保留代码正文、选区与输入法委托，标题栏提供折叠、名称、语言及更多操作。
///
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_code_block.dart';
/// final codeBuilder = CollabCodeBlockComponentBuilder();
/// // 注册到 AppFlowyEditor.blockComponentBuilders['code']。
/// ```
class CollabCodeBlockComponentBuilder extends BlockComponentBuilder {
  /// 验证代码节点拥有纯文本Delta，不改变节点或编辑器。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta != null;

  /// 以借用[blockComponentContext]中的节点和配置创建代码卡片。
  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) =>
      _CodeBlock(
        node: blockComponentContext.node,
        key: blockComponentContext.node.key,
        configuration: configuration,
      );
}

/// 代码卡片借用编辑器节点，不拥有输入法服务或文档连接。
class _CodeBlock extends BlockComponentStatefulWidget {
  /// [key]控制身份复用；[node]和[configuration]由编辑器提供和持有。
  const _CodeBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 创建管理代码块选区、编辑委托及本地只读折叠的状态。
  @override
  createState() => _CodeBlockState();
}

/// 维护文本委托、语法着色缓存和只读折叠；编辑器由页面释放。
class _CodeBlockState extends State<_CodeBlock>
    with SelectableMixin, DefaultSelectableMixin {
  @override
  final forwardKey = GlobalKey(debugLabel: 'code-rich-text');
  @override
  final blockComponentKey = GlobalKey(debugLabel: 'code-block');

  @override
  GlobalKey get containerKey => widget.node.key;

  late final _editor = context.read<EditorState>();

  /// 只读查看时的本地折叠值；恢复编辑后清空并遵循共享属性。
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

  /// 以[anchor]定位名称面板；仅在组件有效且可编辑时提交共享名称。
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

  /// 以[anchor]定位语言选择面板；取消或组件关闭不提交，写入由模型复核权限。
  Future<void> _chooseLanguage(BuildContext anchor) async {
    final id = _blockId;
    if (!_editor.editable || id == null) return;
    final language = await showCodeLanguagePicker(anchor, _metadata.language);
    if (language == null || !mounted) return;
    await changeCollabCodeProperty(_editor, id, 'lang', language);
  }

  /// 切换折叠；借用[_]作为统一回调签名，只读时仅更新本地查看状态。
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

  /// 折叠后移除隐藏正文中的选区与输入连接；关闭或展开状态不处理。
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

  /// 在标题栏创建借用的交互；[key]为测试标记，[child]为内容，
  /// [onTap]为可选异步动作，null禁用；[label]为可选语义名称，
  /// [padding]为内部边距，默认左右4、上下9像素。失败诊断并提示，不上抛异步错误。
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
                  CollabDiagnostics.report(
                    '修改代码块失败',
                    error: error,
                    stackTrace: stackTrace,
                    tag: 'DocCollab',
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

  /// 为借用的[original]文本着色并按正文和语言缓存；不修改Delta，超长文本跳过着色。
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

  /// 将可空的语法[scope]映射到现有代码色板，未知词元沿用正文颜色。
  static Color _tokenColor(String? scope) => switch (scope?.split('.').first) {
    'keyword' || 'operator' => const Color(0xFFD73A49),
    'string' || 'regexp' => const Color(0xFF032F62),
    'number' || 'literal' || 'type' => const Color(0xFF005CC5),
    'function' => const Color(0xFF6F42C1),
    'comment' => const Color(0xFF6A737D),
    'meta' => const Color(0xFFB31D28),
    _ => const Color(0xFF24292E),
  };

  /// 复制当前代码正文；菜单已复核稳定身份、权限与子树快照，完成后不恢复输入。
  /// 剪贴板失败报告诊断与提示，关闭后的组件不再显示结果。
  Future<void> _copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: widget.node.delta?.toPlainText() ?? ''),
      );
      if (!mounted || _editor.isDisposed) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('代码已复制')));
    } catch (error, stackTrace) {
      CollabDiagnostics.report(
        '复制代码失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
      if (mounted && !_editor.isDisposed) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('复制失败，请重试')));
      }
    }
  }

  /// 删除当前稳定身份的代码块；仅支持根/高亮内的可编辑引用。
  /// 删除末块时补空段落，作为一个独立撤销事务；异步失败由更多菜单统一处理。
  Future<void> _delete() async {
    final source = findCollabActionNode(_editor, _blockId ?? widget.node.id);
    if (_editor.isDisposed ||
        !_editor.editable ||
        source == null ||
        source.type != widget.node.type ||
        !const {'page', 'callout'}.contains(source.parent?.type)) {
      return;
    }
    if (_editor.undoManager.undoStack.isNonEmpty) {
      _editor.undoManager.undoStack.last.seal();
    }
    final transaction = _editor.transaction..deleteNode(source);
    if (source.parent!.children.length == 1) {
      final paragraph = paragraphNode();
      paragraph.updateAttributes({
        AppFlowyBlockEditorAdapter.collabBlockIdAttribute: paragraph.id,
      });
      transaction.add(
        InsertOperation(source.path, [paragraph]),
        transform: false,
      );
    }
    transaction.afterSelection = null;
    await _editor.apply(transaction, skipHistoryDebounce: true);
  }

  /// Builds the selectable code and header including sibling insertion in [context].
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
    final child = ListenableBuilder(
      listenable: _editor.editableNotifier,
      builder: (context, _) {
        if (_editor.editable) _previewCollapsed = null;
        final isCollapsed = _previewCollapsed ?? metadata.collapsed;
        return CollabCardFrame(
          surfaceKey: blockComponentKey,
          margin: const EdgeInsets.symmetric(vertical: 4),
          showDivider: !isCollapsed,
          header: CollabCardHeader(
            padding: const EdgeInsets.fromLTRB(3, 4, 4, 4),
            leading: _headerControl(
              key: 'collab-code-collapse',
              label: isCollapsed ? '展开代码块' : '收起代码块',
              onTap: _toggleCollapse,
              padding: const EdgeInsets.all(14),
              child: Icon(
                isCollapsed ? Icons.chevron_right : Icons.expand_more,
                size: 16,
                color: _headerStyle.color,
              ),
            ),
            title: _headerControl(
              key: 'collab-code-name',
              onTap: _editor.editable ? _rename : null,
              child: Text(
                metadata.name.trim().isEmpty ? '代码块' : metadata.name.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            readOnly: !_editor.editable,
            actions: [
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
                    if (_editor.editable)
                      Icon(
                        Icons.expand_more,
                        size: 13,
                        color: _headerStyle.color,
                      ),
                  ],
                ),
              ),
            ],
            more: CollabBlockMoreButton(
              key: ValueKey('block-more-${_blockId ?? widget.node.id}'),
              editor: _editor,
              node: widget.node,
              protectSubtree: true,
              actions: [
                (
                  label: '复制代码',
                  key: const ValueKey('collab-code-copy'),
                  run: _copy,
                ),
                (
                  label: '删除代码块',
                  key: const ValueKey('collab-code-delete'),
                  run: _delete,
                ),
              ],
            ),
          ),
          child: Offstage(
            offstage: isCollapsed,
            child: Container(
              constraints: const BoxConstraints(minHeight: 60),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
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
        );
      },
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
