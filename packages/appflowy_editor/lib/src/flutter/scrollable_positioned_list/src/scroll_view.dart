// Copyright 2019 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// coverage:ignore-file

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'viewport.dart';
import 'wrapping.dart';

/// A version of [CustomScrollView] that allows does not constrict the extents
/// to be within 0 and 1. See [CustomScrollView] for more information.
class UnboundedCustomScrollView extends CustomScrollView {
  final bool _shrinkWrap;

  /// Creates a scroll view that permits an anchor outside the unit interval.
  ///
  /// ```dart
  /// import 'package:appflowy_editor/appflowy_editor.dart';
  /// import 'package:flutter/widgets.dart';
  ///
  /// final view = UnboundedCustomScrollView(
  ///   scrollCacheExtent: const ScrollCacheExtent.pixels(500),
  ///   slivers: const [SliverToBoxAdapter(child: Text('Content'))],
  /// );
  /// ```
  ///
  /// [key] identifies the widget. [scrollDirection] selects the scrolling
  /// axis. [reverse] reverses its direction. [controller] supplies the scroll
  /// position. [primary] opts into the inherited primary controller.
  /// [physics] configures user scrolling. [scrollCacheExtent] controls cached
  /// content. [center] is the key of the center sliver. [slivers] are the
  /// viewport contents. [semanticChildCount] declares semantic children.
  /// [dragStartBehavior] controls drag gesture start behavior.
  const UnboundedCustomScrollView({
    super.key,
    super.scrollDirection,
    super.reverse,
    super.controller,
    super.primary,
    super.physics,
    this._shrinkWrap = false,
    super.center,
    this._anchor = 0.0,
    super.scrollCacheExtent,
    super.slivers,
    super.semanticChildCount,
    super.dragStartBehavior,
  }) : super(shrinkWrap: false);

  // [CustomScrollView] enforces constraints on [CustomScrollView.anchor], so
  // we need our own version.
  final double _anchor;

  @override
  double get anchor => _anchor;

  /// Builds a viewport for [slivers] using [offset] and [axisDirection].
  ///
  /// Uses [context] to resolve the cross-axis direction and [scrollCacheExtent]
  /// to retain the configured cache size.
  @override
  @protected
  Widget buildViewport(BuildContext context, ViewportOffset offset, AxisDirection axisDirection, List<Widget> slivers) {
    if (_shrinkWrap) {
      return CustomShrinkWrappingViewport(
        axisDirection: axisDirection,
        offset: offset,
        slivers: slivers,
        cacheExtent: scrollCacheExtent?.value,
        cacheExtentStyle: scrollCacheExtent?.style ?? CacheExtentStyle.pixel,
        center: center,
        anchor: anchor,
      );
    }
    return UnboundedViewport(
      axisDirection: axisDirection,
      offset: offset,
      slivers: slivers,
      scrollCacheExtent: scrollCacheExtent,
      center: center,
      anchor: anchor,
    );
  }
}
