import 'package:appflowy_editor/appflowy_editor.dart';

/// 将 [attributes] 注册为IME可延续/切分的字符格式；重复注册幂等。
/// 仅扩充AppFlowy的格式目录，不创建编辑器或原生资源。
void registerEditorTextAttributes(Iterable<String> attributes) {
  for (final attribute in attributes) {
    if (!AppFlowyRichTextKeys.supportToggled.contains(attribute)) {
      AppFlowyRichTextKeys.supportToggled.add(attribute);
    }
    if (!AppFlowyRichTextKeys.supportSliced.contains(attribute)) {
      AppFlowyRichTextKeys.supportSliced.add(attribute);
    }
  }
}
