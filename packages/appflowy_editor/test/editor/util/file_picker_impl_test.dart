import 'dart:typed_data';

import 'package:appflowy_editor/src/editor/util/file_picker/file_picker_impl.dart'
    as editor_picker;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';

/// Supplies a readable file without requiring a native file dialog.
final class _PickedFile extends PlatformFile {
  /// Creates a file with [name], [uri], and [contents] for picker tests.
  _PickedFile(this.name, this.uri, this.contents);

  @override
  final String name;

  @override
  final Uri uri;

  /// Bytes returned by [readAsBytes].
  final Uint8List contents;

  /// Test files are read directly and do not expose an XFile adapter.
  @override
  Never get xFile => throw UnimplementedError();

  /// Returns the in-memory byte count without I/O.
  @override
  int? lengthSync() => contents.length;

  /// Completes with the in-memory byte count.
  @override
  Future<int?> length() async => contents.length;

  /// Completes with the test file bytes.
  @override
  Future<Uint8List> readAsBytes() async => contents;

  /// Emits the test file bytes as one chunk.
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(contents);
}

/// Records calls from the editor adapter while controlling picker results.
final class _PickerPlatform extends FilePickerPlatform {
  /// File returned by a single-file selection, or null on cancellation.
  PlatformFile? singleFile;

  /// Files returned by a multiple-file selection; empty means cancellation.
  List<PlatformFile> multipleFiles = [];

  /// URI returned by saving, or null on cancellation.
  Uri? savedUri;

  /// Latest directory dialog title passed to the platform.
  String? directoryTitle;

  /// Latest bytes passed to the save operation.
  Uint8List? savedBytes;

  /// Latest MIME type passed to the save operation.
  String? savedMimeType;

  /// Returns [singleFile] and records no persistent picker resources.
  ///
  /// [dialogTitle], [initialDirectory], [type], [allowedExtensions],
  /// [onFileLoading], [compressionQuality], [androidOptions], [darwinOptions],
  /// [windowsOptions], [linuxOptions], and [webOptions] are accepted to match
  /// the platform API but are not needed by these dispatch tests.
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => singleFile;

  /// Returns [multipleFiles] for a multiple-file selection.
  ///
  /// [dialogTitle], [initialDirectory], [type], [allowedExtensions],
  /// [onFileLoading], [compressionQuality], [androidOptions], [darwinOptions],
  /// [windowsOptions], [linuxOptions], and [webOptions] are accepted to match
  /// the platform API but are not needed by these dispatch tests.
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => multipleFiles;

  /// Records [dialogTitle] and simulates a canceled directory selection.
  ///
  /// [initialDirectory], [androidOptions], [windowsOptions], [linuxOptions],
  /// and [webOptions] are accepted to match the platform API.
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    directoryTitle = dialogTitle;
    return null;
  }

  /// Records [bytes] and [mimeType], then completes with [savedUri].
  ///
  /// [fileName], [dialogTitle], [initialDirectory], [onFileSaving],
  /// [windowsOptions], [linuxOptions], and [webOptions] are accepted to match
  /// the platform API; the returned URI can use a non-file scheme.
  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    savedBytes = bytes;
    savedMimeType = mimeType;
    return savedUri;
  }
}

/// Verifies the editor adapter's single/multiple selection and save contract.
void main() {
  late FilePickerPlatform originalPlatform;
  late _PickerPlatform platform;
  final picker = editor_picker.FilePicker();

  setUp(() {
    originalPlatform = FilePickerPlatform.instance;
    platform = _PickerPlatform();
    FilePickerPlatform.instance = platform;
  });
  tearDown(() => FilePickerPlatform.instance = originalPlatform);

  test('single selection returns a readable URI-backed file', () async {
    final file = _PickedFile(
      'photo.png',
      Uri.parse('content://images/photo'),
      Uint8List.fromList([1, 2, 3]),
    );
    platform.singleFile = file;

    final result = await picker.pickFiles(type: FileType.image);

    expect(result?.files, [same(file)]);
    expect(result?.files.single.path, isNull);
    expect(await result!.files.single.readAsBytes(), [1, 2, 3]);
  });

  test(
    'multiple selection and cancellation use the new picker results',
    () async {
      expect(await picker.pickFiles(), isNull);
      expect(await picker.pickFiles(allowMultiple: true), isNull);

      final file = _PickedFile('a.txt', Uri.file('/tmp/a.txt'), Uint8List(0));
      platform.multipleFiles = [file];
      expect((await picker.pickFiles(allowMultiple: true))?.files, [
        same(file),
      ]);
    },
  );

  test('save returns a URI and preserves bytes and MIME type', () async {
    final bytes = Uint8List.fromList([4, 5]);
    platform.savedUri = Uri.parse('content://documents/export');

    final uri = await picker.saveFile(
      fileName: 'export.pdf',
      bytes: bytes,
      mimeType: 'application/pdf',
    );

    expect(uri, platform.savedUri);
    expect(platform.savedBytes, same(bytes));
    expect(platform.savedMimeType, 'application/pdf');
  });

  test('directory title is forwarded', () async {
    expect(await picker.getDirectoryPath(title: 'Choose folder'), isNull);
    expect(platform.directoryTitle, 'Choose folder');
  });
}
