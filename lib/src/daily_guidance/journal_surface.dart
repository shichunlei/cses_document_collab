import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'journal_draft.dart';
import 'guidance_entries.dart';
import 'journal_editing.dart';
import 'journal_list_markers.dart';
import 'journal_ruled_content.dart';

/// 日记编辑和预览共用的原生文字排版；借用会话，不创建或释放正文。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_surface.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
/// Widget journalBody(LocalJournalController journal) => JournalSurface(
///   editorState: journal.editor.editorState, preview: false, header: Text(journal.date));
/// ```
class JournalSurface extends StatefulWidget {
  /// [key]控制身份，[editorState]由日记会话拥有，[preview]关闭输入、选区和工具栏。
  /// [header]为与正文一起滚动的纸张标题和日期，编辑与预览使用相同布局。
  /// [onCloseSection]接收可选栏目种类，[onMention]接管@；均由宿主持有且可空。
  const JournalSurface({
    super.key,
    required this.editorState,
    required this.preview,
    required this.header,
    this.onCloseSection,
    this.onMention,
  });

  /// 借用的唯一正文会话，调用方必须在视图移除后释放。
  final EditorState editorState;

  /// true为预览；不改变正文、字号或纸张尺寸。
  final bool preview;

  /// 可选栏目关闭回调；null时不显示关闭按钮，回调由业务页面持有。
  final ValueChanged<String>? onCloseSection;

  /// 输入@时打开宿主选人；null不拦截字符，选择完成后由宿主写入受控引用。
  final VoidCallback? onMention;

  /// 随纸张滚动的日期头部，不进入正文历史。
  final Widget header;

  /// 创建本视图拥有的滚动控制器。
  @override
  State<JournalSurface> createState() => _JournalSurfaceState();
}

/// 管理当前视图的滚动资源，正文与保存仍由上层会话持有。
class _JournalSurfaceState extends State<JournalSurface> {
  late final _scroll = EditorScrollController(editorState: widget.editorState);

  /// 释放本视图的滚动控制器，不释放借用正文。
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 调用当前会话的原子纯文本粘贴端口；失败报告给宿主并在仍有效的页面显示提示。
  Future<void> _paste() async {
    final state = widget.editorState;
    try {
      await EditorCommandContext.of(state).pastePlainText?.call();
    } catch (error, stack) {
      EditorCommandContext.report(
        state,
        '日记粘贴失败',
        error: error,
        stackTrace: stack,
      );
      if (mounted && identical(widget.editorState, state)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('粘贴失败，原文已保留，请检查内容或重试')));
      }
    }
  }

  /// 对当前选区执行宿主复制；[cut]为true时仅在剪贴板成功后删除，失败在有效页面提示。
  Future<void> _copy({required bool cut}) async {
    final state = widget.editorState;
    final selection = state.selection;
    if (selection == null || selection.isCollapsed) return;
    try {
      await EditorCommandContext.of(
        state,
      ).copySelection?.call(selection, cut: cut);
    } catch (error, stack) {
      EditorCommandContext.report(
        state,
        '日记复制或剪切失败',
        error: error,
        stackTrace: stack,
      );
      if (mounted && identical(widget.editorState, state)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(cut ? '剪切未删除原文，请重试' : '复制失败，请重试')),
        );
      }
    }
  }

  /// 在[context]按相同字体、宽度和行高构建编辑/预览；栏目内部不创建嵌套编辑器。
  @override
  Widget build(BuildContext context) {
    final state = widget.editorState;
    final config = BlockComponentConfiguration(
      padding: (_) => EdgeInsets.zero,
      placeholderText: (_) => ' ',
      textStyle: (node, {textSpan}) => textSpan?.children != null
          ? const TextStyle()
          : const TextStyle(fontSize: 16, height: 2, color: Color(0xff3e4650)),
    );
    final editor = AppFlowyEditor(
      key: const ValueKey('journal-editor'),
      editorState: state,
      editorScrollController: _scroll,
      header: widget.header,
      editable: !widget.preview,
      disableKeyboardService: widget.preview,
      disableSelectionService: widget.preview,
      showMagnifier: !widget.preview,
      blockComponentBuilders: {
        PageBlockKeys.type: PageBlockComponentBuilder(minimumBodyHeight: 0),
        journalSectionType: _JournalSectionBuilder(
          onClose: widget.preview ? null : widget.onCloseSection,
        ),
        ParagraphBlockKeys.type: GuidanceParagraphBuilder(
          configuration: config,
        ),
        BulletedListBlockKeys.type: BulletedListBlockComponentBuilder(
          configuration: config,
          iconBuilder: buildJournalBulletMarker,
        ),
        NumberedListBlockKeys.type: NumberedListBlockComponentBuilder(
          configuration: config,
          iconBuilder: buildJournalNumberMarker,
        ),
        TodoListBlockKeys.type: TodoListBlockComponentBuilder(
          configuration: config,
          iconBuilder: buildJournalTodoMarker,
        ),
      },
      characterShortcutEvents: [
        if (widget.onMention != null)
          CharacterShortcutEvent(
            key: 'guidance-at',
            character: '@',
            handler: (_) async {
              widget.onMention!();
              return true;
            },
          ),
        journalParagraphEnter,
        formatAsteriskToBulletedList,
        formatMinusToBulletedList,
        formatNumberToNumberedList,
        formatEmptyBracketsToUncheckedBox,
        formatHyphenEmptyBracketsToUncheckedBox,
        formatFilledBracketsToCheckedBox,
        formatHyphenFilledBracketsToCheckedBox,
        formatDoubleAsterisksToBold,
        formatAsteriskToItalic,
        formatDoubleUnderscoresToBold,
        formatUnderscoreToItalic,
        formatDoubleTilesToStrikethrough,
      ],
      commandShortcutEvents: [
        for (final cut in [false, true])
          CommandShortcutEvent(
            key: cut ? 'journal-cut' : 'journal-copy',
            getDescription: () => cut ? '剪切' : '复制',
            command: cut ? 'ctrl+x' : 'ctrl+c',
            macOSCommand: cut ? 'cmd+x' : 'cmd+c',
            handler: (_) {
              if (state.selection == null || state.selection!.isCollapsed) {
                return KeyEventResult.ignored;
              }
              unawaited(_copy(cut: cut));
              return KeyEventResult.handled;
            },
          ),
        for (final shortcut in ['ctrl+v', 'ctrl+shift+v'])
          CommandShortcutEvent(
            key: 'journal-$shortcut',
            getDescription: () => '粘贴纯文本',
            command: shortcut,
            macOSCommand: shortcut.replaceFirst('ctrl', 'cmd'),
            handler: (_) {
              unawaited(_paste());
              return KeyEventResult.handled;
            },
          ),
        ...standardCommandShortcutEvents.where(
          (event) =>
              !event.key.contains('heading') &&
              !event.key.contains('indent') &&
              !event.key.contains('paste') &&
              event.key != copyCommand.key &&
              event.key != cutCommand.key,
        ),
      ],
      editorStyle: EditorStyle.mobile(
        textSpanDecorator: decorateGuidanceMention,
        textScaleFactor: MediaQuery.textScalerOf(context).scale(16) / 16,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        cursorColor: const Color(0xff8b6e63),
        selectionColor: const Color(0x337e6257),
        textStyleConfiguration: const TextStyleConfiguration(
          text: TextStyle(fontSize: 16, height: 2, color: Color(0xff3e4650)),
          lineHeight: 2,
          applyHeightToFirstAscent: true,
          applyHeightToLastDescent: true,
        ),
      ),
    );
    return ColoredBox(
      color: const Color(0xfffaf8f0),
      child: widget.preview
          ? editor
          : EditorInteractionShell(
              editorState: state,
              scrollController: _scroll,
              child: editor,
            ),
    );
  }
}

/// 为动态栏目注册纯结构渲染器，标题不进入可编辑正文。
class _JournalSectionBuilder extends BlockComponentBuilder {
  /// [onClose]由页面处理栏目关闭；null不展示按钮。
  _JournalSectionBuilder({this.onClose});

  /// 借用的业务关闭动作。
  final ValueChanged<String>? onClose;

  /// 使用[context]中的借用栏目构建结构组件。
  @override
  BlockComponentWidget build(BlockComponentContext context) => _JournalSection(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
    onClose: onClose,
  );
}

/// 单个栏目外壳，使用一个编辑器渲染其全部子段落。
class _JournalSection extends BlockComponentStatelessWidget {
  /// [key]保持栏目身份，[node]为受保护的栏目，[configuration]为渲染配置。
  /// [onClose]可空，由宿主负责保存关闭草稿及撤销。
  const _JournalSection({
    super.key,
    required super.node,
    required super.configuration,
    this.onClose,
  });

  /// 可选业务关闭回调，不释放。
  final ValueChanged<String>? onClose;

  /// 在[context]构建动态标题、实际正文行线和最少三行书写空间。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final title = switch (node.attributes['section']) {
      'record' => '今日记录',
      'reflection' => '感悟',
      _ => '自检',
    };
    final lineHeight = MediaQuery.textScalerOf(context).scale(16) * 2;
    return Padding(
      key: ValueKey('journal-section-${node.attributes['section']}'),
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xff9a9387),
                    ),
                  ),
                ),
                if (node.attributes['section'] != 'record' && onClose != null)
                  InkWell(
                    key: ValueKey(
                      'journal-close-${node.attributes['section']}',
                    ),
                    onTap: () => onClose!(node.attributes['section'] as String),
                    child: const Text(
                      '关闭',
                      style: TextStyle(fontSize: 11, color: Color(0xff9a9387)),
                    ),
                  ),
              ],
            ),
          ),
          JournalRuledContent(
            onBlankTap: editor.editable
                ? () => editor.selection = Selection.collapsed(
                    Position(
                      path: node.children.last.path,
                      offset: node.children.last.delta!.length,
                    ),
                  )
                : null,

            textLines: false,
            minimumHeight: lineHeight * 3,
            lineHeight: lineHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final child in node.children)
                  JournalRuledContent(
                    key: ValueKey('journal-lines-${child.id}'),
                    lineHeight: lineHeight,
                    child: IgnorePointer(
                      ignoring: !editor.editable,
                      child: editor.renderer.build(context, child),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
