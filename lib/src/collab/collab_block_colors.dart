import 'package:flutter/material.dart';

/// 桌面 CSS 颜色的展示转换；原值仍保留在协同属性中。
Color? parseCollabBlockColor(String? value) {
  if (value == null) return null;
  final text = value.trim().toLowerCase();
  if (text == 'transparent') return Colors.transparent;
  if (text.startsWith('0x')) {
    final number = int.tryParse(text.substring(2), radix: 16);
    return number == null ? null : Color(number);
  }
  if (text.startsWith('#')) {
    var hex = text.substring(1);
    if (hex.length == 3 || hex.length == 4) {
      hex = hex.split('').map((c) => '$c$c').join();
    }
    final number = int.tryParse(hex, radix: 16);
    if (number == null) return null;
    if (hex.length == 6) return Color(0xff000000 | number);
    if (hex.length == 8) return Color((number >> 8) | ((number & 255) << 24));
  }
  final match = RegExp(r'^rgba?\(([^)]+)\)$').firstMatch(text);
  if (match != null) {
    final parts = match
        .group(1)!
        .split(',')
        .map((v) => double.tryParse(v.trim()))
        .toList();
    if ((parts.length == 3 || parts.length == 4) &&
        parts.every((v) => v != null && v.isFinite)) {
      return Color.fromRGBO(
        parts[0]!.round().clamp(0, 255),
        parts[1]!.round().clamp(0, 255),
        parts[2]!.round().clamp(0, 255),
        (parts.length == 4 ? parts[3]! : 1.0).clamp(0.0, 1.0),
      );
    }
  }
  return const {
    'black': Colors.black,
    'white': Colors.white,
    'red': Color(0xffff0000),
    'blue': Color(0xff0000ff),
    'green': Color(0xff008000),
    'yellow': Color(0xffffff00),
  }[text];
}
