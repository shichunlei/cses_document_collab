import 'journal_draft.dart';

/// 宿主注入的单份日记存储端口，调用由日记会话串行执行，不转移宿主资源所有权。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
/// class MemoryJournalStore implements JournalStore {
///   JournalDraft? draft;
///   @override
///   Future<JournalDraft?> read() async => draft;
///   @override
///   Future<void> write(JournalDraft value) async { draft = value; }
/// }
/// ```
abstract interface class JournalStore {
  /// 读取本机当前分区草稿，无记录返回null；损坏或读取失败须抛错，禁止自动覆盖。
  Future<JournalDraft?> read();

  /// 原子持久化独立[draft]，Future完成表示本机落盘；失败抛错并保留旧记录。
  Future<void> write(JournalDraft draft);
}
