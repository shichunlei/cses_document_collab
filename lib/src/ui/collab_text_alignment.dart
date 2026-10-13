import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_block_colors.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_ordered_marker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 两端对齐由 Flutter 原生排版；分散对齐使用相同文本和 UTF-16 偏移展开字距。
TextAlign collabTextAlign(Node node) =>
    switch (node.attributes[blockComponentAlign]) {
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' || 'distributed' => TextAlign.justify,
      _ => TextAlign.left,
    };

/// 复用标准块的样式与操作，只有分散排版使用自定义文字外壳。
class CollabTextAlignmentBuilder extends BlockComponentBuilder {
  CollabTextAlignmentBuilder(this.standard)
    : super(configuration: standard.configuration) {
    standard.configuration = standard.configuration.copyWith(
      textAlign: collabTextAlign,
    );
    validate = standard.validate;
  }
  final BlockComponentBuilder standard;

  @override
  BlockComponentWidget build(BlockComponentContext context) {
    if (context.node.attributes[blockComponentAlign] != 'distributed') {
      return standard.build(context);
    }
    final original = standard.build(context);
    return _DistributedTextBlock(
      key: context.node.key,
      node: context.node,
      configuration: original.configuration,
      showActions: original.showActions,
      actionBuilder: original.actionBuilder,
      actionTrailingBuilder: original.actionTrailingBuilder,
    );
  }
}

class _DistributedTextBlock extends BlockComponentStatefulWidget {
  const _DistributedTextBlock({
    super.key,
    required super.node,
    required super.configuration,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
  });
  @override
  State<_DistributedTextBlock> createState() => _DistributedTextBlockState();
}

class _DistributedTextBlockState extends State<_DistributedTextBlock>
    with
        SelectableMixin,
        DefaultSelectableMixin,
        BlockComponentConfigurable,
        BlockComponentBackgroundColorMixin,
        BlockComponentTextDirectionMixin {
  @override
  final forwardKey = GlobalKey(debugLabel: 'distributed-rich-text');
  @override
  GlobalKey get containerKey => node.key;
  @override
  final blockComponentKey = GlobalKey(debugLabel: 'distributed-block');
  @override
  Node get node => widget.node;
  @override
  BlockComponentConfiguration get configuration => widget.configuration;
  @override
  late final editorState = context.read<EditorState>();

  Widget? _marker(TextDirection direction) {
    final scale = editorState.editorStyle.textScaleFactor;
    switch (node.type) {
      case NumberedListBlockKeys.type:
        return buildCollabOrderedMarker(context, node, direction);
      case BulletedListBlockKeys.type:
        return SizedBox(
          width: 26 * scale,
          height: 22 * scale,
          child: Center(child: Text('•', textScaler: TextScaler.linear(scale))),
        );
      case TodoListBlockKeys.type:
        return SizedBox(
          width: 26 * scale,
          height: 22 * scale,
          child: Checkbox(
            value: node.attributes[TodoListBlockKeys.checked] == true,
            onChanged: !editorState.editable
                ? null
                : (value) async {
                    await editorState.apply(
                      editorState.transaction
                        ..updateNode(node, {TodoListBlockKeys.checked: value}),
                    );
                  },
          ),
        );
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final direction = calculateTextDirection(
      layoutDirection: Directionality.maybeOf(context),
    );
    final marker = _marker(direction);
    Widget text = LayoutBuilder(
      builder: (context, constraints) {
        return AppFlowyRichText(
          key: forwardKey,
          delegate: this,
          node: node,
          editorState: editorState,
          textAlign: TextAlign.justify,
          textDirection: direction,
          placeholderText: placeholderText,
          placeholderTextSpanDecorator: (span) => span.updateTextStyle(
            placeholderTextStyleWithTextSpan(textSpan: span),
          ),
          textSpanDecorator: (span) {
            var styled = span.updateTextStyle(
              textStyleWithTextSpan(textSpan: span),
            );
            if (node.type == TodoListBlockKeys.type &&
                node.attributes[TodoListBlockKeys.checked] == true) {
              styled = styled.updateTextStyle(
                TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: Colors.grey.shade400,
                ),
              );
            }
            if (node.type == HeadingBlockKeys.type) {
              final level =
                  node.attributes[HeadingBlockKeys.level] as int? ?? 1;
              const sizes = [32.0, 28.0, 24.0, 18.0, 18.0, 18.0];
              styled = styled.updateTextStyle(
                TextStyle(
                  fontSize: level < sizes.length ? sizes[level] : 18,
                  fontWeight: FontWeight.bold,
                ),
              );
            }
            // AppFlowy 同时用此回调修饰单个格式分段；只有完整树参与行布局。
            if (span.children == null) return styled;
            return distributeTextSpan(
              styled,
              width: constraints.maxWidth,
              direction: direction,
              scaler: TextScaler.linear(
                editorState.editorStyle.textScaleFactor,
              ),
            );
          },
          cursorColor: editorState.editorStyle.cursorColor,
          selectionColor: editorState.editorStyle.selectionColor,
          cursorWidth: editorState.editorStyle.cursorWidth,
        );
      },
    );
    if (marker != null) {
      text = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        textDirection: direction,
        children: [
          marker,
          Expanded(child: text),
        ],
      );
    }
    if (node.type == QuoteBlockKeys.type) {
      text = Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color:
                  parseCollabBlockColor(
                    node.attributes[csesBlockBorderColorAttribute] as String?,
                  ) ??
                  const Color(0xff00bcf0),
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.only(left: 8),
        child: text,
      );
    }
    Widget child = Container(
      key: blockComponentKey,
      decoration: decoration,
      padding: padding,
      width: double.infinity,
      child: text,
    );
    child = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      child: child,
    );
    if (widget.showActions && widget.actionBuilder != null) {
      child = BlockComponentActionWrapper(
        node: node,
        actionBuilder: widget.actionBuilder!,
        actionTrailingBuilder: widget.actionTrailingBuilder,
        child: child,
      );
    }
    return child;
  }
}

/// 对每个自然行增加字距；保持原字符串、富文本样式和 UTF-16 光标偏移。
/// 一个字和空行保留自然宽度；内嵌 WidgetSpan 仍交给原生排版，避免重建行内对象。
TextSpan distributeTextSpan(
  TextSpan source, {
  required double width,
  required TextDirection direction,
  TextScaler scaler = TextScaler.noScaling,
}) {
  final plain = source.toPlainText();
  var hasObject = false;
  source.visitChildren((span) {
    if (span is! TextSpan) hasObject = true;
    return true;
  });
  if (plain.isEmpty || !width.isFinite || width <= 0 || hasObject) {
    return source;
  }
  final natural = TextPainter(
    text: source,
    textDirection: direction,
    textScaler: scaler,
  )..layout(maxWidth: width);
  final result = <InlineSpan>[];
  var offset = 0;
  while (offset < plain.length) {
    final boundary = natural.getLineBoundary(TextPosition(offset: offset));
    var end = boundary.end;
    if (end <= offset) end = offset + 1;
    // 换行和行末空白不参与分散；原字符随后原样附回。
    var visibleEnd = end;
    while (visibleEnd > offset &&
        RegExp(r'\s').hasMatch(plain[visibleEnd - 1])) {
      visibleEnd--;
    }
    final line = _sliceSpan(source, offset, visibleEnd);
    final count = plain.substring(offset, visibleEnd).characters.length;
    if (count > 1) {
      final measure = TextPainter(textDirection: direction, textScaler: scaler);
      double lineWidth(double spacing) {
        measure.text = _spaceSpan(line, spacing);
        measure.layout();
        return measure.maxIntrinsicWidth;
      }

      var low = 0.0;
      var high = math.max(0.0, width / count);
      for (var i = 0; i < 12; i++) {
        final mid = (low + high) / 2;
        if (lineWidth(mid) <= width - 0.1) {
          low = mid;
        } else {
          high = mid;
        }
      }
      result.add(_spaceSpan(line, low));
      measure.dispose();
    } else {
      result.add(line);
    }
    if (visibleEnd < end) result.add(_sliceSpan(source, visibleEnd, end));
    offset = end;
    if (offset < plain.length && plain[offset] == '\n') {
      result.add(_sliceSpan(source, offset, offset + 1));
      offset++;
    }
  }
  natural.dispose();
  return TextSpan(style: source.style, children: result);
}

TextSpan _spaceSpan(TextSpan span, double extra, [double inherited = 0]) {
  final original = span.style?.letterSpacing ?? inherited;
  return TextSpan(
    text: span.text,
    style: (span.style ?? const TextStyle()).copyWith(
      letterSpacing: original + extra,
    ),
    recognizer: span.recognizer,
    mouseCursor: span.mouseCursor,
    onEnter: span.onEnter,
    onExit: span.onExit,
    locale: span.locale,
    spellOut: span.spellOut,
    semanticsLabel: span.semanticsLabel,
    children: span.children
        ?.map((child) => _spaceSpan(child as TextSpan, extra, original))
        .toList(),
  );
}

TextSpan _sliceSpan(TextSpan root, int start, int end) {
  var offset = 0;
  TextSpan slice(TextSpan span) {
    final text = span.text ?? '';
    final from = (start - offset).clamp(0, text.length);
    final to = (end - offset).clamp(0, text.length);
    offset += text.length;
    return TextSpan(
      text: text.substring(from, math.max(from, to)),
      style: span.style,
      recognizer: span.recognizer,
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
      locale: span.locale,
      spellOut: span.spellOut,
      children: span.children
          ?.map((child) => slice(child as TextSpan))
          .toList(),
    );
  }

  return slice(root);
}
