import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/blockcraft_snapshot_view.dart';
import 'package:cses_document_collab/src/editor/collab_attachment_block.dart';
import 'package:cses_document_collab/src/editor/collab_audio_block.dart';
import 'package:cses_document_collab/src/editor/collab_block_colors.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_bookmark_block.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_code_block.dart';
import 'package:cses_document_collab/src/editor/collab_code_editing.dart';
import 'package:cses_document_collab/src/editor/collab_person_card_block.dart';
import 'package:cses_document_collab/src/editor/collab_date_card_block.dart';
import 'package:cses_document_collab/src/editor/collab_weather_block.dart';
import 'package:cses_document_collab/src/editor/collab_divider_block.dart';
import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_figma_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_formula_block.dart';
import 'package:cses_document_collab/src/editor/collab_image_block.dart';
import 'package:cses_document_collab/src/editor/collab_inline_formula.dart';
import 'package:cses_document_collab/src/editor/collab_inline_mention.dart';
import 'package:cses_document_collab/src/editor/collab_juejin_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_kr_block.dart';
import 'package:cses_document_collab/src/editor/collab_link_actions.dart';
import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
import 'package:cses_document_collab/src/editor/collab_mermaid_block.dart';
import 'package:cses_document_collab/src/editor/collab_ordered_marker.dart';
import 'package:cses_document_collab/src/editor/collab_page_divider_block.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_text_style.dart';
import 'package:cses_document_collab/src/editor/collab_unsupported_block.dart';
import 'package:cses_document_collab/src/editor/collab_video_block.dart';
import 'package:cses_document_collab/src/editor/collab_web_embed_block.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/editor/core/editor_view_configuration.dart';
import 'package:cses_document_collab/src/editor/editor_interaction_shell.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/editor/editor_text_presentation.dart';
import 'package:cses_document_collab/src/editor/editor_user_mentions.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_kr.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:cses_document_collab/src/model/collab_page_divider.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_task_card.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/ui/modal/collab_editor_display_scope.dart';
import 'package:flutter/material.dart';

import 'collab_inline_entity_mention.dart';
import 'collab_table_block.dart';
import 'collab_table_cell_block.dart';
import 'collab_table_row_block.dart';
import 'collab_task_card_block.dart';

/// 本地与协同共用的正文、快捷栏和划词菜单；只借用编辑会话。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final editor = DocumentEditorController();
/// final view = DocumentEditorView(editorState: editor.editorState);
/// // 将view移出组件树后 await editor.close()。
/// ```
class DocumentEditorView extends StatefulWidget {
  /// [key] 控制身份，[editorState] 必填且由外部释放。
  /// [scrollController] 非空时借用，否则视图创建并释放自己的滚动控制器。
  /// [enabled] 默认true，false隔离未加载文档；[editable] 默认true，false关闭输入与快捷栏。
  /// [padding] 为正文逻辑像素留白，[header]/[footer] 是文档外的可选滚动内容。
  /// [editorKey] 标识内部正文，[onUserMention] 可接管@，null不调用业务服务。
  /// [preview]默认false；true关闭选区、输入、浮栏及正文点击操作，仅显示内容。
  /// [configuration]默认共用展示配置；宿主可注入结构渲染、样式及业务动作，不替换通用命令链。
  const DocumentEditorView({
    super.key,
    required this.editorState,
    this.scrollController,
    this.enabled = true,
    this.editable = true,
    this.preview = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.header,
    this.footer,
    this.editorKey,
    this.onUserMention,
    this.configuration = EditorViewConfiguration.standard,
  });

  /// 必填借用正文，视图不释放文档或同步资源。
  final EditorState editorState;

  /// 可选借用的滚动控制器，须属于同一会话。
  final EditorScrollController? scrollController;

  /// 是否允许文档交互，默认true。
  final bool enabled;

  /// 是否允许编辑，默认true；模型权限仍由会话约束。
  final bool editable;

  /// 是否为纯展示预览，默认false；调用方应提供独立正文快照。
  final bool preview;

  /// 正文留白，默认左右16逻辑像素。
  final EdgeInsets padding;

  /// 可选文档头部，不进入正文树或撤销历史。
  final Widget? header;

  /// 可选文档尾部，不进入正文树或撤销历史。
  final Widget? footer;

  /// 可选正文身份，用于宿主定位或测试。
  final Key? editorKey;

  /// 可选@快捷命令，由所属业务页面提供。
  final Future<bool> Function(EditorState)? onUserMention;

  /// 宿主展示和业务扩展，默认无扩展；生命周期由调用方持有。
  final EditorViewConfiguration configuration;

  /// 创建正文视图的滚动与渲染配置，不接管编辑会话。
  @override
  State<DocumentEditorView> createState() => _DocumentEditorViewState();
}

/// 为每个视图创建独立builder，避免跨文档修改共享配置。
class _DocumentEditorViewState extends State<DocumentEditorView> {
  late EditorScrollController _scroll;
  late Map<String, BlockComponentBuilder> _builders;

  /// 创建滚动和渲染资源；网络与存储由外部数据绑定管理。
  @override
  void initState() {
    super.initState();
    _bind();
  }

  /// 绑定当前会话的滚动资源；自建资源由视图释放，外部滚动控制器仅借用。
  void _bind() {
    _scroll = widget.scrollController ?? EditorScrollController(editorState: widget.editorState);
    _configureBuilders();
  }

  /// 为所有数据来源创建同一组文字/块渲染器，能力过滤后再应用宿主结构和皮肤配置。
  /// 配置不开放被禁止的编辑命令；宿主结构数据仍由宿主事务保护校验。
  void _configureBuilders() {
    _builders = _createDocumentBlockBuilders();
    _builders[PageBlockKeys.type] = PageBlockComponentBuilder(minimumBodyHeight: widget.footer == null ? 0 : null);
    final config = EditorCommandContext.of(widget.editorState).configuration;
    if (!config.documentFeatures) {
      _builders.removeWhere(
        (type, _) =>
            type != PageBlockKeys.type &&
            type != errorBlockComponentBuilderKey &&
            !config.allowsBlock(type, level: config.headingLevels.firstOrNull),
      );
    }
    if (widget.preview) {
      for (final builder in _builders.values) {
        builder.configuration = builder.configuration.copyWith(placeholderText: (_) => '');
      }
    }
    _builders = widget.configuration.blockBuilders?.call(_builders) ?? _builders;
  }

  /// 更换[oldWidget]的会话或滚动配置时成对迁移自有资源；展示配置变化只重建渲染器，借用资源由外部释放。
  @override
  void didUpdateWidget(covariant DocumentEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editorState != widget.editorState || oldWidget.scrollController != widget.scrollController) {
      if (oldWidget.scrollController == null) _scroll.dispose();
      _bind();
    } else if (oldWidget.configuration != widget.configuration ||
        oldWidget.preview != widget.preview ||
        oldWidget.footer != widget.footer) {
      _configureBuilders();
    }
  }

  /// 仅释放自建滚动控制器，不关闭外部会话或借用滚动资源。
  @override
  void dispose() {
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
  }

  /// 在有效的所属会话执行[paste]，失败在当前视图报告并提示。
  Future<void> _paste(Future<void> Function() paste) async {
    final owner = widget.editorState;
    final commandContext = EditorCommandContext.of(owner);
    try {
      await paste();
    } catch (error, stack) {
      if (!mounted ||
          !identical(owner, widget.editorState) ||
          owner.isDisposed ||
          !identical(commandContext, EditorCommandContext.of(owner))) {
        return;
      }
      commandContext.services.report('粘贴失败', error, stack, 'DocEditor');
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('粘贴失败，原文已保留，请检查内容或重试')));
    }
  }

  /// 在当前借用会话复制或[cut]剪切；仅宿主端口成功后才允许删除，迟到错误不进入其他文档。
  Future<void> _copy({required bool cut}) async {
    final owner = widget.editorState;
    final commandContext = EditorCommandContext.of(owner);
    final selection = owner.selection;
    if (selection == null || selection.isCollapsed) return;
    try {
      await commandContext.copySelection?.call(selection, cut: cut);
    } catch (error, stack) {
      if (!mounted ||
          !identical(owner, widget.editorState) ||
          owner.isDisposed ||
          !identical(commandContext, EditorCommandContext.of(owner))) {
        return;
      }
      commandContext.services.report('复制或剪切失败', error, stack, 'DocEditor');
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(cut ? '剪切未删除原文，请重试' : '复制失败，请重试')));
    }
  }

  /// 为[event]使用菜单相同的标题转换事务，保留能力边界、段落属性和宿主元数据。
  CommandShortcutEvent _configureCommand(CommandShortcutEvent event) {
    final level = switch (event.key) {
      'toggle into Heading 1' => 1,
      'toggle into Heading 2' => 2,
      'toggle into Heading 3' => 3,
      'toggle Body' => 0,
      _ => null,
    };
    if (level == null) return event;
    return CommandShortcutEvent(
      key: event.key,
      command: event.command,
      getDescription: () => event.description ?? '切换标题',
      handler: (state) {
        final selection = state.selection;
        if (selection == null || state.isDisposed || !state.editable) return KeyEventResult.ignored;
        final node = state.getNodeAtPath(selection.start.path);
        final body =
            level == 0 || (node?.type == HeadingBlockKeys.type && node?.attributes[HeadingBlockKeys.level] == level);
        unawaited(_applyHeading(state, body ? ParagraphBlockKeys.type : HeadingBlockKeys.type, level));
        return KeyEventResult.handled;
      },
    );
  }

  /// 对借用的[state]应用[blockType]和[level]；统一报告异步命令错误，不保留页面资源。
  Future<void> _applyHeading(EditorState state, String blockType, int level) async {
    try {
      await applyEditorBlockStyle(state, blockType, headingLevel: level == 0 ? null : level);
    } catch (error, stack) {
      EditorCommandContext.report(state, '切换标题失败', error: error, stackTrace: stack);
    }
  }

  /// 为[event]筛选会直接设置输入样式的快捷键，避免禁用格式污染后续输入。
  bool _allowsCommand(CommandShortcutEvent event) {
    final config = EditorCommandContext.of(widget.editorState).configuration;
    if (!config.structuralIndentation && const {'indent', 'outdent'}.contains(event.key)) return false;
    if (event.key.startsWith('toggle into Heading ')) {
      return config.allowsBlock(HeadingBlockKeys.type, level: int.tryParse(event.key.split(' ').last));
    }
    if (config.documentFeatures) return true;
    final attribute = <String, String>{
      'toggle bold': AppFlowyRichTextKeys.bold,
      'toggle italic': AppFlowyRichTextKeys.italic,
      'toggle underline': AppFlowyRichTextKeys.underline,
      'toggle strikethrough': AppFlowyRichTextKeys.strikethrough,
      'toggle code': AppFlowyRichTextKeys.code,
      'toggle highlight': AppFlowyRichTextKeys.backgroundColor,
    }[event.key];
    if (attribute != null) return config.allowsFormat(attribute);
    return !const {'link menu', 'open inline link', 'open links'}.contains(event.key);
  }

  /// 为[event]过滤Markdown转换；不支持的语法保留输入原文，不启动转换事务。
  bool _allowsCharacter(CharacterShortcutEvent event) {
    final config = EditorCommandContext.of(widget.editorState).configuration;
    if (config.documentFeatures) return true;
    final formats = <CharacterShortcutEvent, String>{
      formatDoubleAsterisksToBold: AppFlowyRichTextKeys.bold,
      formatDoubleUnderscoresToBold: AppFlowyRichTextKeys.bold,
      formatAsteriskToItalic: AppFlowyRichTextKeys.italic,
      formatUnderscoreToItalic: AppFlowyRichTextKeys.italic,
      formatTildeToStrikethrough: AppFlowyRichTextKeys.strikethrough,
      formatDoubleTilesToStrikethrough: AppFlowyRichTextKeys.strikethrough,
      formatBackquoteToCode: AppFlowyRichTextKeys.code,
    };
    final attribute = formats[event];
    if (attribute != null) return config.allowsFormat(attribute);
    final types = <CharacterShortcutEvent, String>{
      formatAsteriskToBulletedList: BulletedListBlockKeys.type,
      formatMinusToBulletedList: BulletedListBlockKeys.type,
      formatNumberToNumberedList: NumberedListBlockKeys.type,
      formatDoubleQuoteToQuote: QuoteBlockKeys.type,
      formatEmptyBracketsToUncheckedBox: TodoListBlockKeys.type,
      formatHyphenEmptyBracketsToUncheckedBox: TodoListBlockKeys.type,
      formatFilledBracketsToCheckedBox: TodoListBlockKeys.type,
      formatHyphenFilledBracketsToCheckedBox: TodoListBlockKeys.type,
      formatSignToHeading: HeadingBlockKeys.type,
    };
    final type = types[event];
    if (type != null) return config.allowsBlock(type, level: config.headingLevels.firstOrNull);
    return ![
      slashCommand,
      formatMarkdownLinkToLink,
      convertMinusesToDivider,
      convertStarsToDivider,
      convertUnderscoreToDivider,
    ].contains(event);
  }

  /// 使用[context]构建共用正文；实例配置决定操作，preview禁用选区和输入服务。
  /// 所有数据来源共用黑色缺省字色、输入和菜单链；字符/容器样式及宿主展示配置优先。
  @override
  Widget build(BuildContext context) {
    final state = widget.editorState;
    final commandContext = EditorCommandContext.of(state);
    final paste = commandContext.pastePlainText;
    final copy = commandContext.copySelection;
    final editable = widget.editable && state.editable && !widget.preview;
    final standardStyle = EditorStyle.mobile(
      padding: widget.padding,
      cursorColor: const Color(0xFF5B5BD6),
      dragHandleColor: const Color(0xFF5B5BD6),
      selectionColor: const Color(0x335B5BD6),
      textStyleConfiguration: TextStyleConfiguration(
        text: blockCraftSnapshotRootStyle(state.document.root, const TextStyle(fontSize: 16, color: Colors.black)),
      ),
      textSpanDecorator: decorateEditorTextSpan,
    );
    final editor = IgnorePointer(
      ignoring: !widget.enabled,
      child: Opacity(
        opacity: widget.enabled ? 1 : .45,
        child: AppFlowyEditor(
          key: widget.editorKey,
          editorState: state,
          editorScrollController: _scroll,
          header: widget.header,
          footer: widget.footer,
          editable: editable,
          disableKeyboardService: !editable,
          disableSelectionService: widget.preview,
          showMagnifier: !widget.preview,
          blockComponentBuilders: _builders,
          blockWrapper: widget.preview
              ? (context, {required node, required child}) => IgnorePointer(child: ExcludeFocus(child: child))
              : null,
          characterShortcutEvents: [
            ...widget.configuration.characterShortcuts,
            collabParagraphEnter,
            if (EditorCommandContext.of(state).configuration.allowsBlock(csesCodeBlockType)) collabCodeEnter,
            if (commandContext.configuration.allowsBlock(
              HeadingBlockKeys.type,
              level: commandContext.configuration.headingLevels.firstOrNull,
            ))
              editorHeadingMarkdown,
            if (widget.onUserMention != null)
              CharacterShortcutEvent(key: 'cses-user-mention', character: '@', handler: widget.onUserMention!),
            ...standardCharacterShortcutEvents.where(
              (event) => event != formatSignToHeading && _allowsCharacter(event),
            ),
          ],
          commandShortcutEvents: [
            if (copy != null)
              for (final cut in [false, true])
                CommandShortcutEvent(
                  key: cut ? 'document-editor-cut' : 'document-editor-copy',
                  getDescription: () => cut ? '剪切' : '复制',
                  command: cut ? 'ctrl+x' : 'ctrl+c',
                  macOSCommand: cut ? 'cmd+x' : 'cmd+c',
                  handler: (_) {
                    if (state.selection == null || state.selection!.isCollapsed) return KeyEventResult.ignored;
                    unawaited(_copy(cut: cut));
                    return KeyEventResult.handled;
                  },
                ),
            if (paste != null)
              for (final shortcut in ['ctrl+v', 'ctrl+shift+v'])
                CommandShortcutEvent(
                  key: 'document-editor-$shortcut',
                  getDescription: () => '粘贴纯文本',
                  command: shortcut,
                  macOSCommand: shortcut.replaceFirst('ctrl', 'cmd'),
                  handler: (_) {
                    unawaited(_paste(paste));
                    return KeyEventResult.handled;
                  },
                ),
            collabBlockBackspaceCommand,
            if (commandContext.configuration.hasParagraphLayout) ...[
              collabParagraphTabCommand,
              collabParagraphShiftTabCommand,
            ],
            ...standardCommandShortcutEvents
                .where(
                  (event) =>
                      (paste == null || !event.key.contains('paste')) &&
                      (copy == null || (event.key != copyCommand.key && event.key != cutCommand.key)) &&
                      _allowsCommand(event),
                )
                .map(_configureCommand),
          ],
          shrinkWrap: false,
          editorStyle: widget.configuration.style?.call(context, standardStyle) ?? standardStyle,
        ),
      ),
    );
    return CollabEditorDisplayScope(
      services: EditorCommandContext.of(state).services,
      preview: widget.preview,
      child: EditorInteractionShell(
        key: ObjectKey(state),
        editorState: state,
        scrollController: _scroll,
        enabled: widget.enabled && !widget.preview,
        editable: widget.editable,
        keyboardActions: widget.configuration.keyboardActions,
        child: editor,
      ),
    );
  }
}

/// 正式协同块的渲染器工厂；音频、附件和四类网页使用各自独立构建器。
/// 表格保留行和单元格子树，日期卡片、分页符等无正文块及未知占位使用独立组件。
Map<String, BlockComponentBuilder> _createDocumentBlockBuilders() =>
    {
      ...standardBlockComponentBuilderMap,
      // Renderer validation failures use the same card as native opaque blocks.
      errorBlockComponentBuilderKey: CollabUnsupportedBlockComponentBuilder(),
      HeadingBlockKeys.type: HeadingBlockComponentBuilder(
        configuration: standardBlockComponentBuilderMap[HeadingBlockKeys.type]!.configuration.copyWith(),
      ),
      QuoteBlockKeys.type: QuoteBlockComponentBuilder(iconBuilder: buildCollabQuoteBorder),
      ParagraphBlockKeys.type: ParagraphBlockComponentBuilder(
        configuration: standardBlockComponentBuilderMap[ParagraphBlockKeys.type]!.configuration.copyWith(
          padding: _paragraphBlockPadding,
        ),
      ),
      // 正式图片复用资源块选区外壳并展示尺寸/题注；离线图片仍使用 AppFlowy 原组件。
      ImageBlockKeys.type: CollabImageBlockComponentBuilder(),
      // Links and videos remain first-class selectable editor blocks by providing
      // custom renderers whose URL attributes are synchronized through Rust/Yrs.
      csesLinkBlockType: CollabEmbedBlockComponentBuilder(kind: CollabEmbedKind.link),
      csesVideoBlockType: CollabVideoBlockComponentBuilder(),
      BulletedListBlockKeys.type: BulletedListBlockComponentBuilder(
        configuration: standardBlockComponentConfiguration.copyWith(padding: _listBlockPadding),
      ),
      NumberedListBlockKeys.type: NumberedListBlockComponentBuilder(
        iconBuilder: buildCollabOrderedMarker,
        configuration: standardBlockComponentConfiguration.copyWith(padding: _listBlockPadding),
      ),
      TodoListBlockKeys.type: TodoListBlockComponentBuilder(
        configuration: standardBlockComponentConfiguration.copyWith(padding: _listBlockPadding),
      ),
      'person-card': CollabPersonCardBlockComponentBuilder(),
      'date-card': CollabDateCardBlockComponentBuilder(),
      'weather': CollabWeatherBlockComponentBuilder(),
      collabDividerType: CollabDividerBlockComponentBuilder(),
      collabPageDividerType: CollabPageDividerBlockComponentBuilder(),
      collabFormulaType: CollabFormulaBlockComponentBuilder(),
      'mermaid': CollabMermaidBlockComponentBuilder(),
      collabMeetingType: CollabMeetingBlockComponentBuilder(),
      collabTaskCardType: CollabTaskCardBlockComponentBuilder(),
      collabKrType: CollabKrBlockComponentBuilder(),
      csesCodeBlockType: CollabCodeBlockComponentBuilder(),
      csesCalloutBlockType: CollabCalloutBlockComponentBuilder(),
      'table': CollabTableBlockComponentBuilder(),
      'table-row': CollabTableRowBlockComponentBuilder(),
      'table-cell': CollabTableCellBlockComponentBuilder(),
      csesUnsupportedBlockType: CollabUnsupportedBlockComponentBuilder(),
      'audio': CollabAudioBlockComponentBuilder(),
      'attachment': CollabAttachmentBlockComponentBuilder(),
      'bookmark': CollabBookmarkBlockComponentBuilder(),
      'embed': CollabWebEmbedBlockComponentBuilder(),
      'juejin-embed': CollabJuejinEmbedBlockComponentBuilder(),
      'figma-embed': CollabFigmaEmbedBlockComponentBuilder(),
    }.map((type, builder) {
      const textTypes = {
        ParagraphBlockKeys.type,
        HeadingBlockKeys.type,
        QuoteBlockKeys.type,
        BulletedListBlockKeys.type,
        NumberedListBlockKeys.type,
        TodoListBlockKeys.type,
      };
      return MapEntry(type, textTypes.contains(type) ? configureEditorTextBlock(builder, type) : builder);
    });

/// [node]为布局回调中的当前段落，统一使用上下2逻辑像素留白且保留文字行高。
EdgeInsets _paragraphBlockPadding(Node node) => const EdgeInsets.symmetric(vertical: 2);

/// 为借用的列表 [node] 按0～6级缩进计算正文留白。
EdgeInsets _listBlockPadding(Node node) {
  final value = node.attributes[csesBlockIndentAttribute];
  final indent = value is int ? value.clamp(0, 6) : 0;
  return EdgeInsets.fromLTRB(indent * 28.0, 2, 0, 2);
}

/// 在借用 [context]/[node] 中装饰 UTF-16 [index] 开始的 [text]。
/// [before] 是内置字符格式，[after] 已应用段落/标题样式；段落族保留后者，
/// 再应用行内字号和倍率，避免丢失标题字号或重复乘算段落倍率。
/// 行内公式、用户和三类业务实体提及使用单字符 WidgetSpan，保留文字颜色；
/// 已校验用户复用公开装饰器并绑定当前实例的展示服务。
/// 已转换的桌面行内对象使用原生对象视图；字重及艺术字外观先合成，再继续提及/公式渲染。
/// 整段链接点击提供打开和三视图切换，混排正文维持原链接行为。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final style = EditorStyle.mobile(textSpanDecorator: decorateEditorTextSpan);
/// // 交给借用现有 EditorState 的 AppFlowyEditor，不创建额外资源。
/// ```
InlineSpan decorateEditorTextSpan(
  BuildContext context,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
  TextSpan after,
) {
  var decorated = decorateCollabLinkSpan(
    context,
    node,
    mobileTextSpanDecoratorForAttribute(
      context,
      node,
      index,
      text,
      supportsCollabParagraph(node) ? after : before,
      after,
    ),
  );
  if (supportsCollabParagraph(node)) {
    decorated = decorated.copyWith(
      style: collabParagraphTextStyle(
        node,
        decorated.style ?? const TextStyle(),
        text.attributes ?? const {},
        applyParagraph: false,
      ),
    );
  }
  // Container color is inherited only when the text has no explicit foreground.
  if (text.attributes?[AppFlowyRichTextKeys.textColor] == null) {
    Node? ancestor = node.parent;
    while (ancestor != null) {
      if (ancestor.type == csesCalloutBlockType) {
        final color = parseCollabBlockColor(ancestor.attributes[csesBlockTextColorAttribute] as String?);
        if (color != null) {
          decorated = TextSpan(
            text: decorated.text,
            children: decorated.children,
            style: (decorated.style ?? const TextStyle()).copyWith(color: color),
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
  decorated = blockCraftSnapshotTextStyle(node, text, decorated);
  final snapshotSpan = decorateBlockCraftSnapshotText(node, text, decorated);
  if (snapshotSpan != null) return snapshotSpan;
  final latex = attributes?[collabInlineLatexAttribute];
  final mention = attributes?[collabInlineMentionAttribute];
  if (EditorUserMention.tryRead(attributes) != null) {
    return decorateEditorUserMention(context, node, index, text, before, decorated);
  }
  if (latex is String || mention is String) {
    var offset = index;
    final spans = <InlineSpan>[];
    for (final rune in text.text.runes) {
      if (rune == 0xfffc) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child:
                mention is String && const {'meeting', 'task', 'doc'}.contains(attributes?[collabMentionTypeAttribute])
                ? CollabInlineEntityMention(
                    node: node,
                    offset: offset,
                    name: mention,
                    entityType: attributes![collabMentionTypeAttribute] as String,
                    style: decorated.style ?? before.style ?? const TextStyle(fontSize: 16),
                  )
                : mention is String
                ? CollabInlineMention(
                    node: node,
                    offset: offset,
                    name: mention,
                    userId: attributes?[collabMentionIdAttribute] as String? ?? '',
                    style: decorated.style ?? before.style ?? const TextStyle(fontSize: 16),
                  )
                : CollabInlineFormula(
                    node: node,
                    offset: offset,
                    latex: latex as String,
                    style: decorated.style ?? before.style ?? const TextStyle(fontSize: 16),
                  ),
          ),
        );
      } else {
        spans.add(TextSpan(text: String.fromCharCode(rune), style: decorated.style));
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
      fontFeatures: [if (superscript) const FontFeature.superscripts(), if (subscript) const FontFeature.subscripts()],
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
