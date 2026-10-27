part 'collab_emoji_catalog.g.dart';

/// 桌面同源的原生表情条目，只保存Unicode与搜索文字，不依赖图片或网络。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_emoji_catalog.dart';
/// final emoji = collabEmojiCategories.first.emojis.first;
/// final native = emoji.withSkinTone(0); // 0为默认肤色。
/// ```
class CollabEmoji {
  /// [native] 为默认Unicode，[name] 为中文含义，[search] 为已小写的中英文、拼音及首字母关键词。
  /// [tones] 为五种肤色的完整Unicode序列；空列表表示不支持肤色，不拼接修饰符。
  const CollabEmoji(
    this.native,
    this.name,
    this.search, [
    this.tones = const [],
  ]);

  /// 默认肤色的完整Unicode，包括变体选择符和ZWJ。
  final String native;

  /// 中文名称；数据中没有译名时沿用桌面规则显示原生表情。
  final String name;

  /// 中英文名称、别名、拼音及首字母的小写搜索串。
  final String search;

  /// 按浅到深排列的五个原生肤色序列，或不支持肤色时的空列表。
  final List<String> tones;

  /// 返回[skinTone]对应的完整表情；0为默认，1～5由浅到深，越界或无变体返回默认值。
  String withSkinTone(int skinTone) =>
      skinTone > 0 && skinTone <= tones.length ? tones[skinTone - 1] : native;

  /// 用[query]匹配原生表情、中英文、拼音或首字母关键词；空查询匹配全部。
  /// 多个空白/下划线/连字符分隔的词须同时命中，不修改查询或目录。
  bool matches(String query) => query
      .trim()
      .toLowerCase()
      .split(RegExp(r'[\s_\-]+'))
      .every(
        (term) =>
            native.contains(term) ||
            tones.any((value) => value.contains(term)) ||
            search.contains(term),
      );
}

/// 桌面目录顺序的表情分类，内容为不可变快照，不含最近使用记录。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_emoji_catalog.dart';
/// for (final category in collabEmojiCategories) {
///   print('${category.name}: ${category.emojis.length}');
/// }
/// ```
class CollabEmojiCategory {
  /// [id] 为桌面稳定分类身份，[name] 为中文分类名，[emojis] 保持桌面的原始顺序。
  const CollabEmojiCategory(this.id, this.name, this.emojis);

  /// 分类稳定身份，如people、nature、foods。
  final String id;

  /// 中文分类名称，不写入文档。
  final String name;

  /// 已去除废弃别名与重复项的默认表情及其肤色变体。
  final List<CollabEmoji> emojis;
}

/// 八类桌面同源表情的不可变目录，由包内同步脚本生成。
const List<CollabEmojiCategory> collabEmojiCategories = _desktopEmojiCategories;

/// 数据源的完整许可名称/正文，由选择器注册到Flutter许可页，不含文档资料。
const List<(String, String)> collabEmojiLicenses = _desktopEmojiLicenseNotices;

/// 用于跨分类搜索的只读默认表情列表，不展开肤色变体，避免搜索结果重复。
final List<CollabEmoji> allCollabEmojis = List.unmodifiable(
  collabEmojiCategories.expand((group) => group.emojis),
);

/// 查找完整[native]对应的默认条目或肤色变体；历史自定义前缀不在目录时返回null。
CollabEmoji? findCollabEmoji(String native) {
  for (final emoji in allCollabEmojis) {
    if (emoji.native == native || emoji.tones.contains(native)) return emoji;
  }
  return null;
}
