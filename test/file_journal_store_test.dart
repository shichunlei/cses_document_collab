import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
import 'dart:io';

import 'package:cses_mobile_collab_demo/src/daily_guidance/file_journal_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 验证真正文件的账号隔离、损坏保护、原子失败和草稿重开。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('journal-store-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'actual disk round trip is isolated per account and resumes the stored date',
    () async {
      final first = FileJournalStore(directory: directory, scope: 'account-a');
      final second = FileJournalStore(directory: directory, scope: 'account-b');
      expect(await first.read(), isNull);
      final journal = await LocalJournalController.open(
        store: first,
        now: DateTime(2026, 10, 22),
      );
      journal.setDate('2026-10-21');
      await journal.close();
      expect(await second.read(), isNull);
      final restored = await LocalJournalController.open(
        store: FileJournalStore(directory: directory, scope: 'account-a'),
        now: DateTime(2026, 11, 1),
      );
      expect(restored.date, '2026-10-21');
      expect(restored.dirty, isFalse);
      expect(
        await File(p.join(directory.path, 'account-a.json.tmp')).exists(),
        isFalse,
      );
      await restored.close();
    },
  );

  test(
    'failed temporary write preserves the previously committed file',
    () async {
      final store = FileJournalStore(directory: directory, scope: 'account-a');
      await store.write(JournalDraft.blank(DateTime(2026, 10, 21)));
      final committed = await File(
        p.join(directory.path, 'account-a.json'),
      ).readAsString();
      await Directory(p.join(directory.path, 'account-a.json.tmp')).create();
      await expectLater(
        store.write(JournalDraft.blank(DateTime(2026, 10, 22))),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await File(p.join(directory.path, 'account-a.json')).readAsString(),
        committed,
      );
      expect((await store.read())!.date, '2026-10-21');
    },
  );

  test('damaged or unsupported record is not silently replaced', () async {
    final file = File(p.join(directory.path, 'account-a.json'));
    await file.writeAsString('{damaged');
    final store = FileJournalStore(directory: directory, scope: 'account-a');
    await expectLater(
      LocalJournalController.open(store: store),
      throwsFormatException,
    );
    expect(await file.readAsString(), '{damaged');
    expect(await File('${file.path}.tmp').exists(), isFalse);
  });

  test(
    'uncommitted temporary file is ignored and invalid scopes are rejected',
    () async {
      await File(
        p.join(directory.path, 'account-a.json.tmp'),
      ).writeAsString('{interrupted');
      expect(
        await FileJournalStore(directory: directory, scope: 'account-a').read(),
        isNull,
      );
      expect(
        () => FileJournalStore(directory: directory, scope: '../outside'),
        throwsArgumentError,
      );
    },
  );
}
