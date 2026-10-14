import 'package:dio/dio.dart';

/// A selected source; only the stable remote URL is written to collaborative text.
class EditorMediaSource {
  const EditorMediaSource(this.url, {this.file});
  final String url;
  final EditorLocalFile? file;
}

/// Local selection metadata stays in the sheet until upload succeeds.
class EditorLocalFile {
  const EditorLocalFile({
    required this.path,
    required this.name,
    required this.size,
    required this.mimeType,
  });
  final String path;
  final String name;
  final int size;
  final String mimeType;
}

bool editorMediaSupportsUpload(String kind) =>
    {'image', 'video', 'audio', 'attachment', 'document_cover'}.contains(kind);

int editorMediaMaxBytes(String kind) => switch (kind) {
  'image' || 'document_cover' => 60 * 1024 * 1024,
  'audio' => 50 * 1024 * 1024,
  _ => 100 * 1024 * 1024,
};

/// Validate before requesting upload credentials or reading the selected file.
String? validateEditorMediaFile(String kind, EditorLocalFile file) {
  if (!editorMediaSupportsUpload(kind)) return '此内容仅支持通过链接添加';
  if (file.size <= 0) return '请选择非空文件';
  if (file.size > editorMediaMaxBytes(kind)) {
    return '文件过大，不能超过 ${editorMediaMaxBytes(kind) ~/ (1024 * 1024)} MB';
  }
  final valid = switch (kind) {
    'image' || 'document_cover' => {
      'image/png',
      'image/jpeg',
      'image/gif',
      'image/webp',
    }.contains(file.mimeType),
    'video' => file.mimeType.startsWith('video/'),
    'audio' => file.mimeType.startsWith('audio/'),
    _ => true,
  };
  return valid ? null : '所选文件格式不支持，请重新选择';
}

/// Injectable boundary for the native picker and authenticated CSES upload.
abstract class EditorMediaUploadService {
  Future<EditorLocalFile?> pickFile(String kind);
  Future<EditorMediaSource> upload(
    EditorLocalFile file,
    String kind, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
  });
}
