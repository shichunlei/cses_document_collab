import 'package:flutter/foundation.dart';
import 'markdown_import.dart';
import 'collab_task_card_block.dart';
import 'package:cses_document_collab/src/model/collab_task_card.dart';
import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'collab_inline_entity_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/editor/collab_inline_mention.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/editor/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/editor/collab_formula_block.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/editor/collab_divider_block.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'document_header.dart';

import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/editor/collab_resource_block.dart';

import 'package:cses_document_collab/src/editor/collab_unsupported_block.dart';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_text_alignment.dart';
import 'package:cses_document_collab/src/editor/collab_block_colors.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_code_block.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/collab_ordered_marker.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';

/// A portable, full-screen collaborative editor.
///
/// Connection setup and controller ownership deliberately stay outside this
/// widget. A host application only needs to inject a [CollabController] whose
/// lifecycle is longer than this route.
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final controller = CollabController.localDraft(databasePath: '/host/updates.sqlite');
/// final page = CollaborativeEditorPage(collab: controller);
/// ```
class CollaborativeEditorPage extends StatefulWidget {
  /// 借用 [collab] 展示文档；[key] 控制组件身份与状态复用。
  /// [pickMarkdown] 由宿主选择并读取 UTF-8 Markdown；取消返回 null，失败抛出异常。
  /// null 隐藏导入入口；页面不关闭宿主控制器，导入内容追加至文末。
  const CollaborativeEditorPage({
    super.key,
    required this.collab,
    this.pickMarkdown,
  });

  /// 可选宿主文件选择器；宿主持有文件资源，返回前应限制文件大小并校验编码。
  final Future<String?> Function()? pickMarkdown;

  /// 宿主持有的协同控制器；锁和修订等只读约束由该控制器提供。
  final CollabController collab;

  /// 创建页面展示状态及能力监听；释放时只归还编辑模式控制权。
  @override
  createState() => _CollaborativeEditorPageState();
}

/// 页面持有用户预览选择，并与 Rust 模型能力共同决定编辑器是否允许修改。
class _CollaborativeEditorPageState extends State<CollaborativeEditorPage> {
  bool _isPreview = false;

  /// 导入选择、解析与应用期间禁止重复操作和正文输入。
  bool _importing = false;

  /// 当前借用的文档控制器，不拥有其资源。
  CollabController get collab => widget.collab;

  /// 用户预览和模型只读约束任意一个生效时都使用只读展示。
  bool get _previewOnly => _isPreview || !collab.canEdit;

  /// 注册能力监听，使远端锁定或修订到达后立即关闭本地输入。
  @override
  void initState() {
    super.initState();
    collab.addListener(_syncEditorMode);
    _syncEditorMode();
  }

  /// 根据控制器能力、预览与导入状态同步输入；不连接网络或更改正文。
  void _syncEditorMode() {
    collab.editorState.editable = !_previewOnly && !_importing;
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
    if (!collab.canEdit || _importing) return;
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

  /// 在借用 [state] 的正文光标处先输入@再打开人员选择；取消保留普通@。
  /// 未注入服务/只读/代码块/范围选区返回false交给普通输入；等待面板结束恢复输入。
  Future<bool> _handleUserMention(EditorState state) async {
    final services = CollabRuntime.services;
    if (!mounted ||
        state.isDisposed ||
        !state.editable ||
        services.pickMentionUser == null) {
      return false;
    }
    final selection = state.selection;
    if (selection == null || !selection.isCollapsed) return false;
    final node = state.getNodeAtPath(selection.start.path);
    if (node?.delta == null || node!.type == 'code') return false;
    final offset = selection.start.offset;
    if (offset < 0 || offset > node.delta!.length) return false;
    final transaction = state.transaction..insertText(node, offset, '@');
    transaction.afterSelection = Selection.single(
      path: node.path,
      startOffset: offset + 1,
    );
    await state.apply(transaction);
    if (mounted &&
        !state.isDisposed &&
        state.editable &&
        identical(CollabRuntime.services, services)) {
      await showEditorUserMentionSheet(context, state, replaceTrigger: true);
    }
    return true;
  }

  /// 选择文件后在后台解析，返回当前文档且仍有编辑权限时以单个事务追加。
  /// 取消或失败不写正文；迟到结果不写入已关闭或被替换的文档。
  Future<void> _importMarkdown() async {
    final owner = collab;
    final picker = widget.pickMarkdown;
    if (_importing || _previewOnly || !owner.initialized || picker == null) {
      return;
    }
    final state = owner.editorState;
    final services = CollabRuntime.services;
    setState(() => _importing = true);
    _syncEditorMode();
    state.service.keyboardService?.closeKeyboard();
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导入 Markdown'),
          content: const Text(
            '选择 UTF-8 编码的 .md 文件（最大 5 MB），内容将追加到文末，可撤销。表格转为文本行，独立网络图片转为图片块，其他图片保留地址；不上传本地资源。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('选择文件'),
            ),
          ],
        ),
      );
      if (!mounted ||
          !identical(owner, collab) ||
          confirmed != true ||
          _previewOnly) {
        return;
      }
      final source = await picker();
      if (source == null) return;
      final json = await compute(decodeMarkdownImport, source);
      if (!mounted ||
          !identical(owner, collab) ||
          !owner.canEdit ||
          state.isDisposed) {
        return;
      }
      final nodes = json
          .map((value) => Node.fromJson(Map<String, Object>.from(value)))
          .toList();
      final index = state.document.root.children.length;
      final transaction = state.transaction..insertNodes([index], nodes);
      transaction.afterSelection = null;
      // AppFlowy 对事务也检查 editable；只在提交时打开，页面交互仍由导入状态禁用。
      state.editable = true;
      if (state.undoManager.undoStack.isNonEmpty) {
        state.undoManager.undoStack.last.seal();
      }
      await state.apply(transaction, skipHistoryDebounce: true);
      if (owner.error != null) throw StateError(owner.error!);
      if (mounted && identical(owner, collab)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Markdown 已追加到文末')));
      }
    } catch (error, stack) {
      services.report('Markdown 导入失败', error, stack, 'MarkdownImport');
      if (mounted && identical(owner, collab)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException
                  ? error.message.toString()
                  : '导入失败，请重新选择文件',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
        _syncEditorMode();
      }
    }
  }

  /// 使用 [context] 渲染当前模式和能力；网络和监听由控制器及页面生命周期管理。
  /// 在借用的 [context] 中按连接状态构建编辑页面；业务头部占用header槽，正文仍使用协同块树。
  /// 页面仅管理视图/输入监听，预览隐藏编辑入口，不拥有宿主业务服务。
  @override
  Widget build(BuildContext context) {
    return Localizations.override(
      context: context,
      delegates: const [AppFlowyEditorLocalizations.delegate],
      child: ListenableBuilder(
        listenable: collab,
        builder: (context, _) {
          return Scaffold(
            key: const ValueKey('collaborative-editor-page'),
            backgroundColor: Colors.white,
            appBar: AppBar(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              title: Text(collab.header?.value?.name ?? '协同文档'),
              actions: [
                if (!_previewOnly) ...[
                  IconButton(
                    key: const ValueKey('editor-undo'),
                    tooltip: '撤销',
                    onPressed: _importing
                        ? null
                        : collab.editorState.undoManager.undo,
                    icon: const Icon(Icons.undo),
                  ),
                  IconButton(
                    key: const ValueKey('editor-redo'),
                    tooltip: '重做',
                    onPressed: _importing
                        ? null
                        : collab.editorState.undoManager.redo,
                    icon: const Icon(Icons.redo),
                  ),
                ],
                if (!_previewOnly && widget.pickMarkdown != null)
                  IconButton(
                    key: const ValueKey('editor-import-markdown'),
                    tooltip: '导入 Markdown',
                    onPressed: !_importing && collab.initialized
                        ? _importMarkdown
                        : null,
                    icon: _importing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.file_open_outlined),
                  ),
                Tooltip(
                  message: _previewOnly ? '进入编辑' : '进入预览',
                  child: TextButton.icon(
                    key: const ValueKey('editor-mode-toggle'),
                    onPressed: collab.canEdit && !_importing
                        ? _toggleMode
                        : null,
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
                          // 正式头部使用完整宽度；正文左右留白由每个根块的样式提供。
                          // 本地草稿仍保留顶部留白，SafeArea 负责底部系统边距。
                          padding: EdgeInsets.only(
                            top: collab.header == null ? 20 : 0,
                          ),
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
      ),
    );
  }

  /// 构建原生编辑器，输入遵守用户模式与模型能力；有序/无序/Todo 列表 Enter 在标准快捷键
  /// 之前处理扁平 depth；行首退格先退级再交给容器/媒体边界处理。软键盘通过工具栏注册
  /// 同规则拦截器，硬件命令在下方优先派发，共用事务及现有协同发布链路。
  /// @字符在普通可编辑正文打开宿主人员选择，无服务时保持普通输入。
  Widget _buildEditor() {
    return IgnorePointer(
      ignoring: !collab.initialized,
      child: Opacity(
        opacity: collab.initialized ? 1 : 0.45,
        child: AppFlowyEditor(
          key: const ValueKey('collaborative-appflowy-editor'),
          editorState: collab.editorState,
          header: collab.header == null
              ? null
              : DocumentHeader(
                  controller: collab.header!,
                  editorState: collab.editorState,
                  preview: _isPreview,
                ),
          editable: !_previewOnly && !_importing,
          disableKeyboardService: _previewOnly,
          blockComponentBuilders: _collabBlockComponentBuilders,
          characterShortcutEvents: [
            collabListEnter,
            CharacterShortcutEvent(
              key: 'cses-user-mention',
              character: '@',
              handler: _handleUserMention,
            ),
            ...standardCharacterShortcutEvents,
          ],
          // 列表行首先逐级退级；非列表再保护容器边界/删除前置媒体，最后交标准退格。
          // 不能先让标准命令合并正文，或在退级前删除列表旁的图片/视频。
          commandShortcutEvents: [
            collabBlockBackspaceCommand,
            ...standardCommandShortcutEvents,
          ],
          shrinkWrap: false,
          editorStyle: const EditorStyle.mobile(
            padding: EdgeInsets.symmetric(
              horizontal: DocumentHeader.contentInset,
            ),
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

/// 正式协同块的渲染器工厂；分割线、公式、会议/任务卡片保持无正文结构，未知块使用保护占位。
final Map<String, BlockComponentBuilder> _collabBlockComponentBuilders =
    {
      ...standardBlockComponentBuilderMap,
      // Renderer validation failures use the same card as native opaque blocks.
      errorBlockComponentBuilderKey: CollabUnsupportedBlockComponentBuilder(),
      QuoteBlockKeys.type: QuoteBlockComponentBuilder(
        iconBuilder: buildCollabQuoteBorder,
      ),
      ParagraphBlockKeys.type: ParagraphBlockComponentBuilder(
        configuration:
            standardBlockComponentBuilderMap[ParagraphBlockKeys.type]!
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
      collabDividerType: CollabDividerBlockComponentBuilder(),
      collabFormulaType: CollabFormulaBlockComponentBuilder(),
      collabMeetingType: CollabMeetingBlockComponentBuilder(),
      collabTaskCardType: CollabTaskCardBlockComponentBuilder(),
      csesCodeBlockType: CollabCodeBlockComponentBuilder(),
      csesCalloutBlockType: CollabCalloutBlockComponentBuilder(),
      csesUnsupportedBlockType: CollabUnsupportedBlockComponentBuilder(),
      for (final kind in collabResourceTypes)
        kind: CollabResourceBlockComponentBuilder(),
    }.map((type, builder) {
      const textTypes = {
        ParagraphBlockKeys.type,
        HeadingBlockKeys.type,
        QuoteBlockKeys.type,
        BulletedListBlockKeys.type,
        NumberedListBlockKeys.type,
        TodoListBlockKeys.type,
      };
      return MapEntry(
        type,
        textTypes.contains(type)
            ? CollabTextAlignmentBuilder(builder)
            : builder,
      );
    });

/// Reduces the extra gap between body paragraphs while preserving line height.
EdgeInsets _paragraphBlockPadding(Node node) =>
    const EdgeInsets.symmetric(vertical: 2);

EdgeInsets _listBlockPadding(Node node) {
  final value = node.attributes[csesBlockIndentAttribute];
  final indent = value is int ? value.clamp(0, 6) : 0;
  return EdgeInsets.fromLTRB(indent * 28.0, 2, 0, 2);
}

/// 在借用 [context]/[node] 中装饰 UTF-16 [index] 开始的 [text]。
/// [before] 是内置格式，[after] 为调用方装饰；行内公式、用户和三类业务实体提及使用单字符 WidgetSpan，保留文字颜色。
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
  final latex = attributes?[collabInlineLatexAttribute];
  final mention = attributes?[collabInlineMentionAttribute];
  if (latex is String || mention is String) {
    var offset = index;
    final spans = <InlineSpan>[];
    for (final rune in text.text.runes) {
      if (rune == 0xfffc) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child:
                mention is String &&
                    const {
                      'meeting',
                      'task',
                      'doc',
                    }.contains(attributes?[collabMentionTypeAttribute])
                ? CollabInlineEntityMention(
                    node: node,
                    offset: offset,
                    name: mention,
                    entityType:
                        attributes![collabMentionTypeAttribute] as String,
                    style:
                        decorated.style ??
                        before.style ??
                        const TextStyle(fontSize: 16),
                  )
                : mention is String
                ? CollabInlineMention(
                    node: node,
                    offset: offset,
                    name: mention,
                    userId:
                        attributes?[collabMentionIdAttribute] as String? ?? '',
                    style:
                        decorated.style ??
                        before.style ??
                        const TextStyle(fontSize: 16),
                  )
                : CollabInlineFormula(
                    node: node,
                    offset: offset,
                    latex: latex as String,
                    style:
                        decorated.style ??
                        before.style ??
                        const TextStyle(fontSize: 16),
                  ),
          ),
        );
      } else {
        spans.add(
          TextSpan(text: String.fromCharCode(rune), style: decorated.style),
        );
      }
      offset += rune > 0xffff ? 2 : 1;
    }
    return TextSpan(children: spans);
  }
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
