import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Groups the files returned by one successful picker operation.
class FilePickerResult {
  /// Creates a result containing [files] in the order returned by the platform.
  const FilePickerResult(this.files);

  /// Files selected by the user; cancellation is represented by a null result.
  final List<PlatformFile> files;
}

/// Defines the file operations used by the editor's import and export UI.
///
/// Platform errors are forwarded to callers, which own user-facing error
/// handling. A canceled dialog completes with null for single-result methods.
abstract class FilePickerService {
  /// Opens a directory picker with optional [title] shown by the platform.
  ///
  /// Returns the selected local path or null after cancellation. Platform
  /// failures complete with the exception supplied by the picker plugin.
  Future<String?> getDirectoryPath({String? title});

  /// Opens a file picker and wraps its nonempty result.
  ///
  /// [dialogTitle] and [initialDirectory] configure the native dialog where
  /// supported. [type] and [allowedExtensions] filter visible files; custom
  /// extensions require [type] to be [FileType.custom]. [onFileLoading]
  /// receives platform loading events. [allowMultiple] selects whether one or
  /// several files may be returned. The returned files own their data access
  /// through [PlatformFile.readAsBytes] and may lack a local path.
  ///
  /// Returns null when the user cancels or the platform returns no files.
  /// Platform failures complete with the original exception.
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowMultiple = false,
  });

  /// Saves [bytes] using the platform's save dialog.
  ///
  /// [fileName] is the suggested name and must include any desired extension.
  /// [dialogTitle] and [initialDirectory] configure the dialog when supported.
  /// [mimeType] describes the bytes for platforms that use MIME metadata.
  /// Returns the saved URI, which is not guaranteed to be a local file URI, or
  /// null on cancellation. Platform failures complete with the original
  /// exception. The caller retains ownership of [bytes].
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
    String? dialogTitle,
    String? initialDirectory,
  });
}
