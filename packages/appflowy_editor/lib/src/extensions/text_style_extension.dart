import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

extension TextSpanExtensions on TextSpan {
  TextSpan copyWith({
    String? text,
    TextStyle? style,
    List<InlineSpan>? children,
    GestureRecognizer? recognizer,
    String? semanticsLabel,
  }) {
    return TextSpan(
      text: text ?? this.text,
      style: style ?? this.style,
      children: children ?? this.children,
      recognizer: recognizer ?? this.recognizer,
      semanticsLabel: semanticsLabel ?? this.semanticsLabel,
    );
  }

  TextSpan updateTextStyle(TextStyle? other) {
    if (other == null) {
      return this;
    }
    return copyWith(
      style: style?.combine(other),
      children: children?.map((child) {
        if (child is TextSpan) {
          return child.updateTextStyle(other);
        }
        return child;
      }).toList(growable: false),
    );
  }
}

/// Combines text styles while preserving the receiving style's defaults.
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:flutter/material.dart';
///
/// final style = const TextStyle(fontSize: 14).combine(
///   const TextStyle(fontWeight: FontWeight.bold),
/// );
/// ```
extension TextStyleExtensions on TextStyle {
  /// Combines this style with [other], returning this style when it is `null`.
  ///
  /// A non-inheriting [other] replaces this style entirely. Otherwise its
  /// configured properties override or augment this style.
  TextStyle combine(TextStyle? other) {
    if (other == null) {
      return this;
    }
    if (!other.inherit) {
      return other;
    }

    return copyWith(
      inherit: other.inherit,
      color: other.color,
      backgroundColor: other.backgroundColor,
      fontSize: other.fontSize,
      fontWeight: other.fontWeight,
      fontStyle: other.fontStyle,
      letterSpacing: other.letterSpacing,
      wordSpacing: other.wordSpacing,
      textBaseline: other.textBaseline,
      height: other.height,
      leadingDistribution: other.leadingDistribution,
      locale: other.locale,
      foreground: other.foreground,
      background: other.background,
      shadows: other.shadows,
      fontFeatures: other.fontFeatures,
      fontVariations: other.fontVariations,
      decoration: TextDecoration.combine([
        ?decoration,
        ?other.decoration,
      ]),
      decorationColor: other.decorationColor,
      decorationStyle: other.decorationStyle,
      decorationThickness: other.decorationThickness,
      debugLabel: other.debugLabel,
      fontFamily:
          (other.fontFamily?.isEmpty ?? true) ? fontFamily : other.fontFamily,
      fontFamilyFallback: other.fontFamilyFallback,
      overflow: other.overflow,
    );
  }
}
