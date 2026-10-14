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

import 'package:cses_document_collab/cses_document_collab.dart'
    show
        EditorLocalFile,
        EditorMediaSource,
        EditorMediaUploadService,
        validateEditorMediaFile;

/// 借用Common登录、OSS和文件登记封装的宿主上传端口，不拥有编辑器或HTTP客户端。
/// 文件选择与上传分开，等待期间检查取消和账号/企业/会话变化；仅稳定URL进入协同或头部业务。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/cses_editor_media_upload_service.dart';
/// import 'package:dio/dio.dart';
/// Future<void> uploadIcon() async {
///   const service = CsesEditorMediaUploadService();
///   final file = await service.pickFile('document_icon');
///   if (file == null) return;
///   final cancel = CancelToken();
///   try {
///     await service.upload(file, 'document_icon', cancelToken: cancel, onProgress: (_) {});
///   } finally {
///     cancel.cancel();
///   }
/// }
/// ```
class CsesEditorMediaUploadService implements EditorMediaUploadService {
  /// 创建无状态上传端口；使用前由宿主完成Common登录，服务不持有连接或账号副本。
  const CsesEditorMediaUploadService();

  /// 为资源 [kind] 打开单文件选择器并返回路径/MIME/大小，取消返回null；SVG仅图标允许。
  /// 文件和选择器由系统/宿主管理，选择失败按Future异常传给来源面板。
  @override
  Future<EditorLocalFile?> pickFile(String kind) async {
    final picked = await FilePicker.pickFile(
      type: switch (kind) {
        'image' || 'document_banner' || 'document_icon' => FileType.custom,
        'video' => FileType.video,
        'audio' => FileType.audio,
        _ => FileType.any,
      },
      allowedExtensions:
          kind == 'image' ||
              kind == 'document_banner' ||
              kind == 'document_icon'
          ? [
              'png',
              'jpg',
              'jpeg',
              'gif',
              'webp',
              if (kind == 'document_icon') 'svg',
            ]
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

  /// 上传借用的 [file] 至资源 [kind] 对应OSS桶并登记；[cancelToken] 由调用方创建和取消。
  /// [onProgress] 报告0～1进度；Future仅在会话未变化且文件登记完成后返回稳定URL。
  /// 文件变化、账号变化、取消或网络失败向调用方抛出；服务不关闭Common客户端。
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
      'image' || 'document_banner' || 'document_icon' => 'picture',
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
