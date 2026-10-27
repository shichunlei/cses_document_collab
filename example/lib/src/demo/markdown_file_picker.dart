import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

/// 打开单个 Markdown 文件并返回严格 UTF-8 文本；取消返回 null。
/// 文件由系统持有；最多读取 5 MiB + 1 字节，后台执行读取与解码，失败抛出异常。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/markdown_file_picker.dart';
/// final markdown = await pickMarkdownFile();
/// ```
Future<String?> pickMarkdownFile() async {
  final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['md', 'markdown']);
  if (file == null) return null;
  if (!RegExp(r'\.(md|markdown)$', caseSensitive: false).hasMatch(file.name)) {
    throw const FormatException('请选择 .md 或 .markdown 文件');
  }
  final path = file.path;
  if (path == null) throw const FormatException('无法读取所选文件');
  return compute(_readMarkdown, path);
}

/// 后台读取 [path] 指向的借用文件，严格校验 5 MiB 上限和 UTF-8 编码。
/// 流读取结束或失败均关闭句柄；不会删除或更改原文件。
Future<String> _readMarkdown(String path) async {
  const limit = 5 * 1024 * 1024;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in File(path).openRead(0, limit + 1)) {
    bytes.add(chunk);
  }
  if (bytes.length > limit) throw const FormatException('Markdown 文件不能超过 5 MB');
  try {
    return utf8.decode(bytes.takeBytes());
  } on FormatException {
    throw const FormatException('文件不是有效的 UTF-8 编码，请转换后重试');
  }
}
