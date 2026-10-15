// Copyright 2019 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// coverage:ignore-file

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'element_registry.dart';
import 'item_positions_listener.dart';
import 'item_positions_notifier.dart';
import 'scroll_view.dart';
import 'wrapping.dart';

/// A list of widgets similar to [ListView], except scroll control
/// and position reporting is based on index rather than pixel offset.
///
/// [PositionedList] lays out children in the same way as [ListView].
///
/// The list can be displayed with the item at [positionIndex] positioned at a
/// particular [alignment].  See [ItemScrollController.jumpTo] for an
/// explanation of alignment.
///
/// All other parameters are the same as specified in [ListView].
class PositionedList extends StatefulWidget {
  /// Create a [PositionedList].
  /// [key] controls identity; [itemCount] and [itemBuilder] define indexed children.
  /// [separatorBuilder] optionally separates indexed children; [controller] supplies scrolling.
  /// [itemPositionsNotifier] receives laid-out positions; [positionedIndex] is the anchor index, default zero.
  /// [alignment] is its viewport fraction, default zero; [scrollDirection] defaults to vertical.
  /// [reverse] and [shrinkWrap] default to false; [physics] overrides scrolling behavior.
  /// [padding] insets indexed content; [cacheExtent] is the logical-pixel layout cache.
  /// [semanticChildCount] overrides accessible count; [addSemanticIndexes],
  /// [addRepaintBoundaries] and [addAutomaticKeepAlives] default to true.
  /// [footer] is non-indexed trailing content; [minimumContentExtent] reserves non-negative logical pixels before it, default zero.
  const PositionedList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.separatorBuilder,
    this.controller,
    this.itemPositionsNotifier,
    this.positionedIndex = 0,
    this.alignment = 0,
    this.scrollDirection = Axis.vertical,
    this.reverse = false,
    this.shrinkWrap = false,
    this.physics,
    this.padding,
    this.cacheExtent,
    this.semanticChildCount,
    this.addSemanticIndexes = true,
    this.addRepaintBoundaries = true,
    this.addAutomaticKeepAlives = true,
    this.footer,
    this.minimumContentExtent = 0,
  }) : assert(
         minimumContentExtent >= 0 && minimumContentExtent < double.infinity,
       ),
       assert((positionedIndex == 0) || (positionedIndex < itemCount));

  /// Optional non-indexed content rendered after the list and minimum extent gap.
  final Widget? footer;

  /// Minimum main-axis extent before [footer], in logical pixels; zero disables filling.
  final double minimumContentExtent;

  /// Number of items the [itemBuilder] can produce.
  final int itemCount;

  /// Called to build children for the list with
  /// 0 <= index < itemCount.
  final IndexedWidgetBuilder itemBuilder;

  /// If not null, called to build separators for between each item in the list.
  /// Called with 0 <= index < itemCount - 1.
  final IndexedWidgetBuilder? separatorBuilder;

  /// An object that can be used to control the position to which this scroll
  /// view is scrolled.
  final ScrollController? controller;

  /// Notifier that reports the items laid out in the list after each frame.
  final ItemPositionsNotifier? itemPositionsNotifier;

  /// Index of an item to initially align to a position within the viewport
  /// defined by [alignment].
  final int positionedIndex;

  /// Determines where the leading edge of the item at [positionedIndex]
  /// should be placed.
  ///
  /// See [ItemScrollController.jumpTo] for an explanation of alignment.
  final double alignment;

  /// The axis along which the scroll view scrolls.
  ///
  /// Defaults to [Axis.vertical].
  final Axis scrollDirection;

  /// Whether the view scrolls in the reading direction.
  ///
  /// Defaults to false.
  ///
  /// See [ScrollView.reverse].
  final bool reverse;

  /// Whether the extent of the scroll view in the [scrollDirection] should be
  /// determined by the contents being viewed.
  ///
  ///  Defaults to false.
  ///
  /// See [ScrollView.shrinkWrap].
  final bool shrinkWrap;

  /// How the scroll view should respond to user input.
  ///
  /// For example, determines how the scroll view continues to animate after the
  /// user stops dragging the scroll view.
  ///
  /// See [ScrollView.physics].
  final ScrollPhysics? physics;

  /// {@macro flutter.widgets.scrollable.cacheExtent}
  final double? cacheExtent;

  /// The number of children that will contribute semantic information.
  ///
  /// See [ScrollView.semanticChildCount] for more information.
  final int? semanticChildCount;

  /// Whether to wrap each child in an [IndexedSemantics].
  ///
  /// See [SliverChildBuilderDelegate.addSemanticIndexes].
  final bool addSemanticIndexes;

  /// The amount of space by which to inset the children.
  final EdgeInsets? padding;

  /// Whether to wrap each child in a [RepaintBoundary].
  ///
  /// See [SliverChildBuilderDelegate.addRepaintBoundaries].
  final bool addRepaintBoundaries;

  /// Whether to wrap each child in an [AutomaticKeepAlive].
  ///
  /// See [SliverChildBuilderDelegate.addAutomaticKeepAlives].
  final bool addAutomaticKeepAlives;

  @override
  State<StatefulWidget> createState() => _PositionedListState();
}

class _PositionedListState extends State<PositionedList> {
  final Key _centerKey = UniqueKey();

  /// Measures reverse content before the anchor, so index jumps retain the same minimum extent.
  final GlobalKey _leadingKey = GlobalKey();

  final registeredElements = ValueNotifier<Set<Element>?>(null);
  late final ScrollController scrollController;

  bool updateScheduled = false;

  @override
  void initState() {
    super.initState();
    scrollController = widget.controller ?? ScrollController();
    scrollController.addListener(_schedulePositionNotificationUpdate);
    _schedulePositionNotificationUpdate();
  }

  @override
  void dispose() {
    scrollController.removeListener(_schedulePositionNotificationUpdate);
    scrollController.dispose();
    registeredElements.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PositionedList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedulePositionNotificationUpdate();
  }

  /// Builds lazily indexed content in [context] and fills only its missing minimum extent before the footer.
  /// The reverse sliver contributes its extent when navigation changes the anchor index.
  @override
  Widget build(BuildContext context) => RegistryWidget(
    elementNotifier: registeredElements,
    child: UnboundedCustomScrollView(
      anchor: widget.alignment,
      center: _centerKey,
      controller: scrollController,
      scrollDirection: widget.scrollDirection,
      reverse: widget.reverse,
      scrollCacheExtent: widget.cacheExtent == null
          ? null
          : ScrollCacheExtent.pixels(widget.cacheExtent!),
      physics: widget.physics,
      shrinkWrap: widget.shrinkWrap,
      semanticChildCount: widget.semanticChildCount ?? widget.itemCount,
      slivers: <Widget>[
        if (widget.positionedIndex > 0)
          SliverPadding(
            key: _leadingKey,
            padding: _leadingSliverPadding,
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => widget.separatorBuilder == null
                    ? _buildItem(context, widget.positionedIndex - (index + 1))
                    : _buildSeparatedListElement(
                        context,
                        2 * widget.positionedIndex - (index + 1),
                      ),
                childCount: widget.separatorBuilder == null
                    ? widget.positionedIndex
                    : 2 * widget.positionedIndex,
                addSemanticIndexes: false,
                addRepaintBoundaries: widget.addRepaintBoundaries,
                addAutomaticKeepAlives: widget.addAutomaticKeepAlives,
              ),
            ),
          ),
        SliverPadding(
          key: _centerKey,
          padding: _centerSliverPadding,
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => widget.separatorBuilder == null
                  ? _buildItem(context, index + widget.positionedIndex)
                  : _buildSeparatedListElement(
                      context,
                      index + 2 * widget.positionedIndex,
                    ),
              childCount: widget.itemCount != 0 ? 1 : 0,
              addSemanticIndexes: false,
              addRepaintBoundaries: widget.addRepaintBoundaries,
              addAutomaticKeepAlives: widget.addAutomaticKeepAlives,
            ),
          ),
        ),
        if (widget.positionedIndex >= 0 &&
            widget.positionedIndex < widget.itemCount - 1)
          SliverPadding(
            padding: _trailingSliverPadding,
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => widget.separatorBuilder == null
                    ? _buildItem(context, index + widget.positionedIndex + 1)
                    : _buildSeparatedListElement(
                        context,
                        index + 2 * widget.positionedIndex + 1,
                      ),
                childCount: widget.separatorBuilder == null
                    ? widget.itemCount - widget.positionedIndex - 1
                    : 2 * (widget.itemCount - widget.positionedIndex - 1),
                addSemanticIndexes: false,
                addRepaintBoundaries: widget.addRepaintBoundaries,
                addAutomaticKeepAlives: widget.addAutomaticKeepAlives,
              ),
            ),
          ),
        if (widget.footer != null)
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final leading =
                  _leadingKey.currentContext?.findRenderObject()
                      as RenderSliver?;
              final preceding =
                  constraints.precedingScrollExtent +
                  (widget.positionedIndex > 0
                      ? leading?.geometry?.scrollExtent ?? 0
                      : 0);
              final gap = (widget.minimumContentExtent - preceding).clamp(
                0.0,
                double.infinity,
              );
              return SliverToBoxAdapter(
                child: Padding(
                  padding: switch (constraints.axisDirection) {
                    AxisDirection.down => EdgeInsets.only(top: gap),
                    AxisDirection.up => EdgeInsets.only(bottom: gap),
                    AxisDirection.right => EdgeInsets.only(left: gap),
                    AxisDirection.left => EdgeInsets.only(right: gap),
                  },
                  child: widget.footer,
                ),
              );
            },
          ),
      ],
    ),
  );

  Widget _buildSeparatedListElement(BuildContext context, int index) {
    if (index.isEven) {
      return _buildItem(context, index ~/ 2);
    } else {
      return widget.separatorBuilder!(context, index ~/ 2);
    }
  }

  Widget _buildItem(BuildContext context, int index) {
    return RegisteredElementWidget(
      key: ValueKey(index),
      child: widget.addSemanticIndexes
          ? IndexedSemantics(
              index: index,
              child: widget.itemBuilder(context, index),
            )
          : widget.itemBuilder(context, index),
    );
  }

  EdgeInsets get _leadingSliverPadding =>
      (widget.scrollDirection == Axis.vertical
          ? widget.reverse
                ? widget.padding?.copyWith(top: 0)
                : widget.padding?.copyWith(bottom: 0)
          : widget.reverse
          ? widget.padding?.copyWith(left: 0)
          : widget.padding?.copyWith(right: 0)) ??
      const EdgeInsets.all(0);

  EdgeInsets get _centerSliverPadding => widget.scrollDirection == Axis.vertical
      ? widget.reverse
            ? widget.padding?.copyWith(
                    top: widget.positionedIndex == widget.itemCount - 1
                        ? widget.padding!.top
                        : 0,
                    bottom: widget.positionedIndex == 0
                        ? widget.padding!.bottom
                        : 0,
                  ) ??
                  const EdgeInsets.all(0)
            : widget.padding?.copyWith(
                    top: widget.positionedIndex == 0 ? widget.padding!.top : 0,
                    bottom: widget.positionedIndex == widget.itemCount - 1
                        ? widget.padding!.bottom
                        : 0,
                  ) ??
                  const EdgeInsets.all(0)
      : widget.reverse
      ? widget.padding?.copyWith(
              left: widget.positionedIndex == widget.itemCount - 1
                  ? widget.padding!.left
                  : 0,
              right: widget.positionedIndex == 0 ? widget.padding!.right : 0,
            ) ??
            const EdgeInsets.all(0)
      : widget.padding?.copyWith(
              left: widget.positionedIndex == 0 ? widget.padding!.left : 0,
              right: widget.positionedIndex == widget.itemCount - 1
                  ? widget.padding!.right
                  : 0,
            ) ??
            const EdgeInsets.all(0);

  EdgeInsets get _trailingSliverPadding =>
      widget.scrollDirection == Axis.vertical
      ? widget.reverse
            ? widget.padding?.copyWith(bottom: 0) ?? const EdgeInsets.all(0)
            : widget.padding?.copyWith(top: 0) ?? const EdgeInsets.all(0)
      : widget.reverse
      ? widget.padding?.copyWith(right: 0) ?? const EdgeInsets.all(0)
      : widget.padding?.copyWith(left: 0) ?? const EdgeInsets.all(0);

  void _schedulePositionNotificationUpdate() {
    if (!updateScheduled) {
      updateScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        // A pending position update can outlive its list when an editor route
        // closes during a scroll. The owning list has already disposed the
        // notifier in that case, so no position should be published.
        if (!mounted) {
          updateScheduled = false;
          return;
        }
        final elements = registeredElements.value;
        if (elements == null) {
          updateScheduled = false;
          return;
        }
        final positions = <ItemPosition>[];
        RenderViewportBase? viewport;
        for (var element in elements) {
          final RenderBox box = element.renderObject as RenderBox;
          viewport ??= RenderAbstractViewport.of(box) as RenderViewportBase?;
          var anchor = 0.0;
          if (viewport is RenderViewport) {
            anchor = viewport.anchor;
          }

          if (viewport is CustomRenderViewport) {
            anchor = viewport.anchor;
          }

          final ValueKey<int> key = element.widget.key as ValueKey<int>;
          // Skip this element if `box` has never been laid out.
          if (!box.hasSize) continue;
          if (widget.scrollDirection == Axis.vertical) {
            final reveal = viewport!.getOffsetToReveal(box, 0).offset;
            if (!reveal.isFinite) continue;
            final itemOffset =
                reveal - viewport.offset.pixels + anchor * viewport.size.height;
            positions.add(
              ItemPosition(
                index: key.value,
                itemLeadingEdge:
                    itemOffset.round() /
                    scrollController.position.viewportDimension,
                itemTrailingEdge:
                    (itemOffset + box.size.height).round() /
                    scrollController.position.viewportDimension,
              ),
            );
          } else {
            final itemOffset = box
                .localToGlobal(Offset.zero, ancestor: viewport)
                .dx;
            if (!itemOffset.isFinite) continue;
            positions.add(
              ItemPosition(
                index: key.value,
                itemLeadingEdge:
                    (widget.reverse
                            ? scrollController.position.viewportDimension -
                                  (itemOffset + box.size.width)
                            : itemOffset)
                        .round() /
                    scrollController.position.viewportDimension,
                itemTrailingEdge:
                    (widget.reverse
                            ? scrollController.position.viewportDimension -
                                  itemOffset
                            : (itemOffset + box.size.width))
                        .round() /
                    scrollController.position.viewportDimension,
              ),
            );
          }
        }
        widget.itemPositionsNotifier?.itemPositions.value = positions;
        updateScheduled = false;
      });
    }
  }
}
