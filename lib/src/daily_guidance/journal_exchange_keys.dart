/// 桌面meta中的版本化今日导向业务信息。
const journalBlockCraftNamespace = 'mobileGuidance';

/// 已转换完整桌面内容的本地草稿标记，用于选择完整块渲染与校验。
const journalDesktopImportAttribute = 'guidance_desktop_import';

/// 普通桌面文档的展示模式，不额外输出今日导向栏目标题或纸张装饰。
const journalPlainDesktopAttribute = 'guidance_plain_desktop';

/// 校验借用的[value]为路径到稳定ID的有界表并返回独立副本；非法路径、身份或重复ID抛FormatException。
Map<String, String> journalBlockIdentities(Object? value) {
  if (value is! Map || value.length > 5000) {
    throw const FormatException('文档块身份表无效');
  }
  final result = <String, String>{};
  final ids = <String>{};
  for (final entry in value.entries) {
    if (entry.key is! String ||
        !RegExp(r'^(?:[0-9]+(?:\.[0-9]+)*)?$').hasMatch(entry.key as String) ||
        entry.value is! String ||
        (entry.value as String).isEmpty ||
        (entry.value as String).length > 256 ||
        !ids.add(entry.value as String)) {
      throw const FormatException('文档块身份表无效');
    }
    result[entry.key as String] = entry.value as String;
  }
  return result;
}
