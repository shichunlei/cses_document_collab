import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'journal_draft.dart';
import 'guidance_entries.dart';
import 'journal_editing.dart';
import 'journal_list_markers.dart';
import 'journal_ruled_content.dart';

/// 日记纸张展示配置；通过共用DocumentEditorView提供编辑和预览，借用会话，不释放正文。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_surface.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
/// Widget journalBody(LocalJournalController journal) => JournalSurface(
///   editorState: journal.editor.editorState, preview: false, header: Text(journal.date));
/// ```
class JournalSurface extends StatelessWidget {
  /// [key]控制身份，[editorState]由日记会话拥有，[preview]关闭输入、选区和工具栏。
  /// [header]为与正文一起滚动的纸张标题和日期，编辑与预览使用相同布局。
  /// [onCloseSection]接收可选栏目种类，由宿主持有且可空。
  /// [keyboardActions]为宿主自定义快捷项，默认空；工具栏等待每个动作完成，模态输入恢复由宿主负责。
  const JournalSurface({
    super.key,
    required this.editorState,
    required this.preview,
    required this.header,
    this.onCloseSection,
    this.keyboardActions = const [],
  });

  /// 借用的唯一正文会话，调用方必须在视图移除后释放。
  final EditorState editorState;

  /// true为预览；不改变正文、字号或纸张尺寸。
  final bool preview;

  /// 可选栏目关闭回调；null时不显示关闭按钮，回调由业务页面持有。
  final ValueChanged<String>? onCloseSection;

  /// 宿主提供的自定义工具栏动作；预览不显示，回调及其业务资源由宿主持有。
  final List<EditorKeyboardAction> keyboardActions;

  /// 随纸张滚动的日期头部，不进入正文历史。
  final Widget header;

  /// 在[context]注入纸张样式、栏目结构及业务动作；输入、菜单、选区和剪贴板均由共用视图维护。
  /// 编辑/预览使用同一排版配置，正文与滚动资源由共享组件按公开契约管理。
  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xfffaf8f0),
      child: DocumentEditorView(
        editorState: editorState,
        preview: preview,
        header: header,
        editorKey: const ValueKey('journal-editor'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        onUserMention: (state) =>
            handleEditorUserMentionTrigger(context, state),
        configuration: EditorViewConfiguration(
          keyboardActions: keyboardActions,
          characterShortcuts: [journalParagraphEnter],
          style: (context, style) => style.copyWith(
            textSpanDecorator: decorateGuidanceMention,
            textScaleFactor: MediaQuery.textScalerOf(context).scale(16) / 16,
            cursorColor: const Color(0xff8b6e63),
            selectionColor: const Color(0x337e6257),
            textStyleConfiguration: const TextStyleConfiguration(
              text: TextStyle(
                fontSize: 16,
                height: 2,
                color: Color(0xff3e4650),
              ),
              lineHeight: 2,
              applyHeightToFirstAscent: true,
              applyHeightToLastDescent: true,
            ),
          ),
          blockBuilders: (builders) {
            final config = BlockComponentConfiguration(
              padding: (_) => EdgeInsets.zero,
              placeholderText: (_) => ' ',
              textStyle: (node, {textSpan}) => textSpan?.children != null
                  ? const TextStyle()
                  : const TextStyle(
                      fontSize: 16,
                      height: 2,
                      color: Color(0xff3e4650),
                    ),
            );
            final paperBuilders = <String, BlockComponentBuilder>{
              PageBlockKeys.type: PageBlockComponentBuilder(
                minimumBodyHeight: 0,
              ),
              journalSectionType: _JournalSectionBuilder(
                onClose: preview ? null : onCloseSection,
              ),
              ParagraphBlockKeys.type: ParagraphBlockComponentBuilder(
                configuration: config,
              ),
              HeadingBlockKeys.type: HeadingBlockComponentBuilder(
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
            };
            return {
              ...builders,
              ...paperBuilders.map(
                (type, builder) => MapEntry(
                  type,
                  type == PageBlockKeys.type || type == journalSectionType
                      ? builder
                      : GuidanceTextBlockBuilder(
                          configureEditorTextBlock(
                            builder,
                            type,
                            listIndentWidth: 28,
                          ),
                        ),
                ),
              ),
            };
          },
        ),
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
