import 'dart:typed_data';

import 'package:appflowy_editor/src/editor/util/file_picker/file_picker_service.dart';
import 'package:file_picker/file_picker.dart' as fp;

/// Adapts the platform file picker to the editor's file service contract.
class FilePicker implements FilePickerService {
  /// Requests a directory and forwards [title] to the native dialog.
  ///
  /// Returns a local path or null after cancellation. Platform exceptions
  /// propagate unchanged to the caller.
  @override
  Future<String?> getDirectoryPath({String? title}) =>
      fp.FilePicker.getDirectoryPath(dialogTitle: title);

  /// Picks one file unless [allowMultiple] requests several.
  ///
  /// [dialogTitle], [initialDirectory], [type], [allowedExtensions], and
  /// [onFileLoading] are forwarded to the picker. An empty selection becomes
  /// null; the returned files are read through their own asynchronous APIs.
  /// Platform exceptions propagate unchanged.
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    fp.FileType type = fp.FileType.any,
    List<String>? allowedExtensions,
    Function(fp.FilePickerStatus)? onFileLoading,
    bool allowMultiple = false,
  }) async {
    if (allowMultiple) {
      final files = await fp.FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        initialDirectory: initialDirectory,
        type: type,
        allowedExtensions: allowedExtensions,
        onFileLoading: onFileLoading,
      );
      return files.isEmpty ? null : FilePickerResult(files);
    }

    final file = await fp.FilePicker.pickFile(
      dialogTitle: dialogTitle,
      initialDirectory: initialDirectory,
      type: type,
      allowedExtensions: allowedExtensions,
      onFileLoading: onFileLoading,
    );
    return file == null ? null : FilePickerResult([file]);
  }

  /// Saves [bytes] as [fileName] through the native save dialog.
  ///
  /// [mimeType], [dialogTitle], and [initialDirectory] are forwarded where
  /// supported. Returns the saved URI or null after
  /// cancellation; failures propagate unchanged. [bytes] remain caller owned.
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
    String? dialogTitle,
    String? initialDirectory,
  }) => fp.FilePicker.saveFile(
    fileName: fileName,
    bytes: bytes,
    mimeType: mimeType,
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
  );
}
