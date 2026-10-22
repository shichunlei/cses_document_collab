import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

import 'guidance_entries.dart';

/// 宿主日记栏目的节点类型，仅用于本地文档，不是桌面BlockCraft协议。
const journalSectionType = 'local-journal-section';

/// 可添加栏目的稳定语义键；显示名称不用于恢复或识别正文。
const journalSections = ['record', 'reflection', 'self-check'];

/// 日记文字、列表与基本格式；宿主另外校验自己的行内引用和业务属性。
final journalConfiguration = EditorConfiguration(
  blocks: const [
    EditorBlock.paragraph,
    EditorBlock.bulletedList,
    EditorBlock.numberedList,
    EditorBlock.todoList,
  ],
  inlineFormats: const {
    EditorInlineFormat.bold,
    EditorInlineFormat.italic,
    EditorInlineFormat.underline,
    EditorInlineFormat.strikethrough,
  },
  alignments: const {},
  fontSizes: const [],
  lineHeight: false,
  nextParagraphStyle: false,
  keyboardToolbarItems: const [
    EditorKeyboardToolbarItem.blockType,
    EditorKeyboardToolbarItem.textStyle,
  ],
);

/// 单份本地日记的不可变保存快照，正文JSON与编辑会话不共享可变对象。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
/// final draft = JournalDraft.blank(DateTime.now());
/// final restored = JournalDraft.fromJson(draft.toJson());
/// print(restored.date);
/// ```
final class JournalDraft {
  /// [id]为稳定草稿身份，[date]为不随设备时区重新解释的YYYY-MM-DD记录日期。
  /// [createdAt]/[updatedAt]为UTC时间，[timezoneOffsetMinutes]为建档地相对UTC的分钟偏移。
  /// [documentJson]为已通过validateJournalDocument校验的独立正文序列化值。
  /// [needsMigration]默认false；读取旧版后的true提示控制器安排原子升级保存。
  const JournalDraft({
    required this.id,
    required this.date,
    required this.createdAt,
    required this.updatedAt,
    required this.timezoneOffsetMinutes,
    required this.documentJson,
    this.needsMigration = false,
  });

  /// 以本地[now]的日期创建仅含今日记录的空草稿；不分配编辑器或存储资源。
  factory JournalDraft.blank(DateTime now) {
    final document = Document(
      root: Node(
        type: 'page',
        children: [
          for (final section in journalSections.take(1))
            Node(
              type: journalSectionType,
              attributes: {'section': section},
              children: [paragraphNode()],
            ),
        ],
      ),
    );
    try {
      return JournalDraft(
        id: 'journal-${now.microsecondsSinceEpoch}',
        date: journalDate(now),
        createdAt: now.toUtc(),
        updatedAt: now.toUtc(),
        timezoneOffsetMinutes: now.timeZoneOffset.inMinutes,
        documentJson: jsonEncode(document.toJson()),
      );
    } finally {
      document.dispose();
    }
  }

  /// 校验并恢复持久化[json]；未知版本、非法日期或正文抛FormatException，不静默覆盖。
  factory JournalDraft.fromJson(Map<String, dynamic> json) {
    final date = json['date'];
    final created = DateTime.tryParse(json['createdAt']?.toString() ?? '');
    final updated = DateTime.tryParse(json['updatedAt']?.toString() ?? '');
    final offset = json['timezoneOffsetMinutes'];
    final id = json['id'];
    final legacy = json['schemaVersion'] == 1;
    if ((!legacy && json['schemaVersion'] != 2) ||
        json['templateId'] != 'ruled-daily' ||
        json['templateVersion'] != (legacy ? 1 : 2) ||
        id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        date is! String ||
        !isJournalDate(date) ||
        created == null ||
        updated == null ||
        offset is! int ||
        offset.abs() > 840 ||
        json['document'] is! Map<String, dynamic>) {
      throw const FormatException('日记草稿格式或版本无效');
    }
    Document? document;
    try {
      document = Document.fromJson(json['document'] as Map<String, dynamic>);
      if (legacy) _upgradeLegacyJournal(document);
      validateJournalDocument(document);
      return JournalDraft(
        id: id,
        date: date,
        createdAt: created.toUtc(),
        updatedAt: updated.toUtc(),
        timezoneOffsetMinutes: offset,
        documentJson: jsonEncode(document.toJson()),
        needsMigration: legacy,
      );
    } catch (_) {
      throw const FormatException('日记正文损坏或包含不支持的内容');
    } finally {
      document?.dispose();
    }
  }

  /// 本机草稿身份，由创建者生成，编辑和重开保持。
  final String id;

  /// 用户选择的记录日期，固定为YYYY-MM-DD。
  final String date;

  /// 首次创建UTC时间，修改日期不会改写。
  final DateTime createdAt;

  /// 当前保存快照对应的UTC修改时间。
  final DateTime updatedAt;

  /// 创建时区的UTC分钟偏移，历史记录不随设备时区改变。
  final int timezoneOffsetMinutes;

  /// 旧版读取后需要持久化升级；不会在读取时写盘或覆盖原文件。
  final bool needsMigration;

  /// 独立正文JSON；本地节点不直接发送给桌面协同服务。
  final String documentJson;

  /// 返回可交给JSON编码器的独立保存对象，不持有编辑器引用。
  Map<String, dynamic> toJson() => {
    'schemaVersion': 2,
    'templateId': 'ruled-daily',
    'templateVersion': 2,
    'id': id,
    'date': date,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'timezoneOffsetMinutes': timezoneOffsetMinutes,
    'document': jsonDecode(documentJson),
  };
}

/// 将[date]的年月日格式化为YYYY-MM-DD，不转换时区。
String journalDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// 检查[value]是1900～2100年间的真实YYYY-MM-DD日期，拒绝日期溢出归一化。
bool isJournalDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final date = DateTime.tryParse(value);
  return date != null &&
      date.year >= 1900 &&
      date.year <= 2100 &&
      journalDate(date) == value;
}

/// 已关闭栏目的完整节点快照保存在根属性中，不参与可见正文选区或预览。
const journalClosedSectionsAttribute = 'guidance_closed_sections';

/// 获取借用的[document]中已关闭栏目；返回新节点，不与可编辑树共享可变对象。
List<Node> closedJournalSections(Document document) {
  final value =
      document.root.attributes[journalClosedSectionsAttribute] ?? const [];
  if (value is! List || value.length > 2) throw const FormatException('关闭栏目无效');
  return value
      .map((item) => Node.fromJson(Map<String, Object>.from(item as Map)))
      .toList();
}

/// 校验借用的[document]的动态栏目、受控引用与总容量；非法时抛FormatException。
/// 可见和关闭栏目共享稳定语义身份，今日记录必须位于可见内容首位且不可关闭。
void validateJournalDocument(Document document) {
  final sections = document.root.children.toList();
  if (document.root.type != 'page' ||
      sections.isEmpty ||
      sections.first.attributes['section'] != 'record') {
    throw const FormatException('今日记录缺失');
  }
  final all = [...sections, ...closedJournalSections(document)];
  final kinds = <String>{};
  var count = 0;
  var length = 0;
  var references = 0;
  for (final section in all) {
    final kind = section.attributes['section'];
    if (section.type != journalSectionType ||
        !journalSections.contains(kind) ||
        !kinds.add(kind as String) ||
        section.delta != null ||
        section.children.isEmpty) {
      throw const FormatException('日记栏目结构无效');
    }
    for (final node in section.children) {
      if (!isJournalTextNode(node)) throw const FormatException('日记包含不支持的正文');
      final entry = node.attributes[guidanceEntryAttribute];
      if (entry != null &&
          (node.type != ParagraphBlockKeys.type ||
              !const {'task', 'help', 'pilot'}.contains(entry) ||
              node.attributes['guidance_entry_id'] is! String ||
              node.attributes['guidance_done'] is! bool)) {
        throw const FormatException('业务条目无效');
      }
      count++;
      length += node.delta!.length;
      references += journalDeltaMentionCount(node.delta!);
    }
  }
  if (references > 500 ||
      count > journalConfiguration.maxBlocks ||
      length > journalConfiguration.maxCharacters) {
    throw const FormatException('日记正文超过容量');
  }
}

/// 检查借用的[node]为受支持的文字叶子，已知提及占一个模型位置。
bool isJournalTextNode(Node node) =>
    journalConfiguration.allowsBlock(node.type) &&
    node.children.isEmpty &&
    node.delta != null &&
    node.delta!.every((op) => op is TextInsert) &&
    validJournalDelta(node.delta!, complete: true);

/// 检查[delta]只含基础格式或受控提及；[complete]为true时同时验证对象和引用属性成对出现。
/// 补丁可暂时只含格式retain，合成后的完整文字仍须再次校验。
bool validJournalDelta(Delta delta, {bool complete = false}) {
  try {
    for (final op in delta) {
      final attributes = {...?op.attributes};
      final mention = attributes.remove(guidanceMentionAttribute);
      if (!journalConfiguration.allowsTextAttributes(attributes)) return false;
      if (mention != null) {
        readGuidanceMention({guidanceMentionAttribute: mention});
        if (op is TextInsert && op.text.runes.any((rune) => rune != 0xfffc)) {
          return false;
        }
      }
      if (op is TextInsert && op.text.contains('\uFFFC') && mention == null) {
        return false;
      }
      if (complete && op is! TextInsert) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// 在独立恢复的[document]中迁移v1固定三栏；非空或带列表语义的栏目始终保留。
/// 空可选栏目保存到关闭区；日期、正文、格式和栏目顺序不重写，读取不产生磁盘副作用。
void _upgradeLegacyJournal(Document document) {
  final sections = document.root.children.toList();
  if (sections.length != 3 || document.root.type != 'page') {
    throw const FormatException('旧日记栏目缺失');
  }
  final closed = <Map<String, Object>>[];
  for (var i = 0; i < sections.length; i++) {
    final section = sections[i];
    if (section.type != journalSectionType ||
        section.attributes['section'] != journalSections[i] ||
        section.children.isEmpty ||
        section.delta != null ||
        section.children.any(
          (node) =>
              !isJournalTextNode(node) ||
              node.delta!.toPlainText().contains('\uFFFC') ||
              node.attributes[guidanceEntryAttribute] != null,
        )) {
      throw const FormatException('旧日记结构无效');
    }
  }
  for (var i = sections.length - 1; i > 0; i--) {
    final section = sections[i];
    if (section.children.every(
      (node) =>
          node.type == ParagraphBlockKeys.type &&
          node.delta!.isEmpty &&
          node.attributes.keys.every((key) => key == blockComponentDelta),
    )) {
      closed.insert(0, section.toJson());
      document.delete([i], 1);
    }
  }
  if (closed.isNotEmpty) {
    document.update([], {journalClosedSectionsAttribute: closed});
  }
}

/// 统计已校验[delta]中的原子引用；最多500个引用与每引用1024字节预算共同保护本地文件容量。
int journalDeltaMentionCount(Delta delta) =>
    delta.whereType<TextInsert>().fold<int>(
      0,
      (sum, op) =>
          sum + op.text.codeUnits.where((unit) => unit == 0xfffc).length,
    );
