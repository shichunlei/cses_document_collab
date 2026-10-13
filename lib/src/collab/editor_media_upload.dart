import 'dart:io';

import 'package:cses_common/core/text/string_util.dart';
import 'package:cses_common/resource/file_drive/resource_file_repository.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_common/storage/oss/factory/oss_client_factory.dart';
import 'package:cses_common/storage/oss/models/request_option.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';

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

class CsesEditorMediaUploadService implements EditorMediaUploadService {
  const CsesEditorMediaUploadService();

  @override
  Future<EditorLocalFile?> pickFile(String kind) async {
    final picked = await FilePicker.pickFile(
      type: switch (kind) {
        'image' || 'document_cover' => FileType.custom,
        'video' => FileType.video,
        'audio' => FileType.audio,
        _ => FileType.any,
      },
      allowedExtensions: kind == 'image' || kind == 'document_cover'
          ? ['png', 'jpg', 'jpeg', 'gif', 'webp']
          : null,
    );
    if (picked == null) return null;
    if (picked.path == null) throw const FormatException('无法读取所选文件，请重新选择');
    final file = EditorLocalFile(
      path: picked.path!,
      name: picked.name,
      size: await picked.length() ?? 0,
      mimeType: lookupMimeType(picked.name) ?? 'application/octet-stream',
    );
    final error = validateEditorMediaFile(kind, file);
    if (error != null) throw FormatException(error);
    return file;
  }

  @override
  Future<EditorMediaSource> upload(
    EditorLocalFile file,
    String kind, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
  }) async {
    final error = validateEditorMediaFile(kind, file);
    if (error != null) throw FormatException(error);
    final userId = User().userId;
    final cookie = ctx.cookieId;
    final company = User().companyId;
    if (userId == null || userId.isEmpty || cookie == null || cookie.isEmpty) {
      throw const FormatException('请先登录 CSES 后再上传文件');
    }
    void checkSession() {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if (User().userId != userId ||
          ctx.cookieId != cookie ||
          User().companyId != company) {
        throw const FormatException('登录状态已变化，请重新选择文件');
      }
    }

    checkSession();
    final actualSize = await File(file.path).length();
    if (actualSize != file.size) throw const FormatException('文件已发生变化，请重新选择');
    final bucket = switch (kind) {
      'image' || 'document_cover' => 'picture',
      'video' => 'video',
      'audio' => 'audio',
      _ => 'attachment',
    };
    final id = StringUtil.newId();
    final suffix = file.name.contains('.')
        ? '.${file.name.split('.').last.toLowerCase()}'
        : '';
    final key = '$userId/$id$suffix';
    final client = await OssClientFactory.initForBucket(bucket);
    checkSession();
    // The low-level client leaves the user's original file untouched.
    final response = await client.putObjectFile(
      file.path,
      fileKey: key,
      cancelToken: cancelToken,
      option: PutRequestOption(
        onSendProgress: (sent, total) {
          if (total > 0) onProgress((sent / total).clamp(0, 1));
        },
      ),
    );
    if (response.statusCode != 200) throw const FormatException('文件上传失败，请重试');
    checkSession();
    final now = DateTime.now().millisecondsSinceEpoch;
    final registered = await ResourceFileRepository.addFile({
      'file': {
        'id': id,
        'ossType': 'ALIYUN_OSS',
        'bucket': bucket,
        'uri': key,
        'name': file.name,
        'size': file.size,
        'createdTime': now,
        'timestamp': now,
        'version': 1.0,
      },
      'categoryId': 'personal',
      'categoryName': 'personal',
    });
    if (!registered.isSuccess) throw const FormatException('文件保存失败，请重试');
    checkSession();
    // Match Common's bucket CDN contract; never persist a short-lived signed URL.
    return EditorMediaSource(
      Uri.https('$bucket.jinqidongli.com', '/$key').toString(),
      file: file,
    );
  }
}
