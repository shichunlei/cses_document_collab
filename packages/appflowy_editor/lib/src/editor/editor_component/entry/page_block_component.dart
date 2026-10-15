import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/block_component/base_component/widget/ignore_parent_gesture.dart';
import 'package:appflowy_editor/src/flutter/scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class PageBlockKeys {
  static const String type = 'page';
}

Node pageNode({
  required Iterable<Node> children,
  Attributes attributes = const {},
}) {
  return Node(
    type: PageBlockKeys.type,
    children: children,
    attributes: attributes,
  );
}

/// Renders root pages with an optional minimum height before their footer.
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// final builders = {
///   ...standardBlockComponentBuilderMap,
///   PageBlockKeys.type: PageBlockComponentBuilder(minimumBodyHeight: 600),
/// };
/// ```
class PageBlockComponentBuilder extends BlockComponentBuilder {
  /// [minimumBodyHeight] is the non-negative logical-pixel height reserved for header/body before the footer; defaults to zero, null fills the bounded viewport.
  PageBlockComponentBuilder({this.minimumBodyHeight = 0})
    : assert(minimumBodyHeight == null || minimumBodyHeight >= 0);

  /// Minimum header/body height before the footer; null fills the viewport without inflating individual blocks.
  final double? minimumBodyHeight;

  /// Builds the root described by [blockComponentContext], borrowing its header/footer and editor state.
  @override
  BlockComponentWidget build(BlockComponentContext blockComponentContext) {
    return PageBlockComponent(
      key: blockComponentContext.node.key,
      node: blockComponentContext.node,
      header: blockComponentContext.header,
      footer: blockComponentContext.footer,
      wrapper: blockComponentContext.wrapper,
      minimumBodyHeight: minimumBodyHeight,
    );
  }
}

/// Root renderer that borrows editor services and keeps footer space outside document nodes.
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// final page = PageBlockComponent(
///   node: pageNode(children: [paragraphNode(text: 'Body')]),
///   minimumBodyHeight: 600,
/// );
/// // Used by the root builder inside AppFlowyEditor, which supplies editor services.
/// ```
class PageBlockComponent extends BlockComponentStatelessWidget {
  /// [key] controls identity; [node] is the borrowed page node.
  /// [showActions] controls block actions; [actionBuilder] and [actionTrailingBuilder] override action UI.
  /// [configuration] controls inherited block appearance; [header] and [footer] are optional root-only content.
  /// [wrapper] wraps each document block; [minimumBodyHeight] is non-negative logical pixels before the footer, default zero; null fills a bounded viewport.
  const PageBlockComponent({
    super.key,
    required super.node,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
    super.configuration = const BlockComponentConfiguration(),
    this.header,
    this.footer,
    this.wrapper,
    this.minimumBodyHeight = 0,
  });

  /// Minimum header/body height in logical pixels; null fills the bounded viewport, zero disables filling.
  final double? minimumBodyHeight;

  /// Optional root header, included in the minimum body height.
  final Widget? header;

  /// Optional root footer, excluded from the minimum body height.
  final Widget? footer;

  /// Optional wrapper for document blocks; does not wrap the header or footer.
  final BlockComponentWrapper? wrapper;

  /// Builds the page's header, document blocks, and footer from [context].
  ///
  /// Reads the editor and optional scroll controller from the widget tree.
  /// Large pages use a lazy list; short pages fill [minimumBodyHeight] before the non-indexed footer.
  @override
  Widget build(BuildContext context) {
    final height = minimumBodyHeight;
    if (height != null || footer == null) {
      return _buildPage(context, height ?? 0);
    }
    return LayoutBuilder(
      builder: (context, constraints) => _buildPage(
        context,
        constraints.hasBoundedHeight ? constraints.maxHeight : 0,
      ),
    );
  }

  /// Renders the header/body in [context] with [bodyHeight] logical pixels reserved before the footer.
  /// Only the missing extent is filled; document node heights and lazy rendering stay unchanged.
  Widget _buildPage(BuildContext context, double bodyHeight) {
    final editorState = context.read<EditorState>();
    final scrollController = context.read<EditorScrollController?>();
    final items = node.children;

    if (scrollController == null || scrollController.shrinkWrap) {
      return SingleChildScrollView(
        child: Builder(
          builder: (context) {
            final scroller = Scrollable.maybeOf(context);
            if (scroller != null) {
              editorState.updateAutoScroller(scroller);
            }
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: footer == null ? 0 : bodyHeight,
                  ),
                  child: Column(
                    children: [
                      ?header,
                      ...items.map((e) {
                        Widget child = editorState.renderer.build(context, e);
                        if (wrapper != null) {
                          child = wrapper!(context, node: e, child: child);
                        }
                        return Container(
                          constraints: BoxConstraints(
                            maxWidth:
                                editorState.editorStyle.maxWidth ??
                                double.infinity,
                          ),
                          padding: editorState.editorStyle.padding,
                          child: child,
                        );
                      }),
                    ],
                  ),
                ),
                ?footer,
              ],
            );
          },
        ),
      );
    } else {
      int extentCount = 0;
      if (header != null) extentCount++;

      return ScrollablePositionedList.builder(
        footer: footer == null
            ? null
            : IgnoreEditorSelectionGesture(child: footer!),
        minimumContentExtent: bodyHeight,
        shrinkWrap: scrollController.shrinkWrap,
        scrollDirection: Axis.vertical,
        itemCount: items.length + extentCount,
        itemBuilder: (context, index) {
          editorState.updateAutoScroller(Scrollable.of(context));
          if (header != null && index == 0) {
            return IgnoreEditorSelectionGesture(child: header!);
          }

          final node = items[index - (header != null ? 1 : 0)];
          Widget child = editorState.renderer.build(context, node);
          if (wrapper != null) {
            child = wrapper!(context, node: node, child: child);
          }

          return Center(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: editorState.editorStyle.maxWidth ?? double.infinity,
              ),
              padding: editorState.editorStyle.padding,
              child: child,
            ),
          );
        },
        itemScrollController: scrollController.itemScrollController,
        scrollOffsetController: scrollController.scrollOffsetController,
        itemPositionsListener: scrollController.itemPositionsListener,
        scrollOffsetListener: scrollController.scrollOffsetListener,
      );
    }
  }
}
