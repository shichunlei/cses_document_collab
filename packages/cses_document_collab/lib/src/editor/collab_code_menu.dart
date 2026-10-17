import 'package:cses_document_collab/src/model/collab_code_languages.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 在借用的 [context] 锚点输入代码块 [name]，完整退场后返回名称，取消返回 null。
Future<String?> showCodeNameEditor(BuildContext context, String name) => showCollabPopover<String>(
  context: context,
  title: '代码块名称',
  requestFocus: true,
  builder: (_) => _CodeNameEditor(name: name),
);

/// 在借用的 [context] 锚点选择代码 [language]，完整退场后返回语言，取消返回 null。
Future<String?> showCodeLanguagePicker(BuildContext context, String language) => showCollabPopover<String>(
  context: context,
  title: '代码语言',
  builder: (_) => _CodeLanguagePicker(language: language),
);

/// 拥有名称输入副本的局部表单。
class _CodeNameEditor extends StatefulWidget {
  /// [name] 为初始名称，不写共享状态。
  const _CodeNameEditor({required this.name});

  /// 打开时的名称副本，输入状态由本组件持有。
  final String name;

  /// 创建拥有输入控制器的状态。
  @override
  State<_CodeNameEditor> createState() => _CodeNameEditorState();
}

/// 输入控制器随浮层创建和释放，确认只返回字符串。
class _CodeNameEditorState extends State<_CodeNameEditor> {
  late final _controller = TextEditingController(text: widget.name)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.name.length);

  /// 去除首尾空白并返回名称，空字符串由调用方解释为清除名称。
  void _save() => Navigator.of(context).pop(_controller.text.trim());

  /// 退场时释放本状态拥有的输入控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 在借用 [context] 中展示外置标签和显式取消/保存，名称最多256字符。
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(6),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CollabModalField(
          label: '名称',
          child: TextField(
            key: const ValueKey('collab-code-name-input'),
            controller: _controller,
            autofocus: true,
            maxLength: 256,
            decoration: const InputDecoration(hintText: '输入代码块名称', counterText: ''),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
          ),
        ),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          spacing: 10,
          children: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            FilledButton(key: const ValueKey('collab-code-name-save'), onPressed: _save, child: const Text('保存')),
          ],
        ),
      ],
    ),
  );
}

/// 搜索和选择语言，不接管代码编辑器。
class _CodeLanguagePicker extends StatefulWidget {
  /// [language] 为当前语言，用于选中标记及置顶。
  const _CodeLanguagePicker({required this.language});

  /// 当前语言标识，用于置顶和勾选，不直接写入正文。
  final String language;

  /// 创建仅持有本地搜索词的状态。
  @override
  State<_CodeLanguagePicker> createState() => _CodeLanguagePickerState();
}

/// 语言搜索只在内存清单中过滤，无异步或外部资源。
class _CodeLanguagePickerState extends State<_CodeLanguagePicker> {
  String _query = '';

  /// 在借用 [context] 中展示搜索与惰性语言列表，选中后返回原语言标识。
  @override
  Widget build(BuildContext context) {
    final languages = collabCodeLanguages.keys
        .where(
          (lang) =>
              lang.toLowerCase().contains(_query.toLowerCase()) || (lang == 'PlainText' && '纯文本'.contains(_query)),
        )
        .toList();
    if (languages.remove(widget.language)) languages.insert(0, widget.language);
    return SizedBox(
      key: const ValueKey('collab-code-language-menu'),
      height: 350,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 9),
            child: TextField(
              key: const ValueKey('collab-code-language-search'),
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(hintText: '搜索语言'),
            ),
          ),
          Expanded(
            child: languages.isEmpty
                ? const Center(child: Text('没有匹配的语言'))
                : ListView.builder(
                    itemCount: languages.length,
                    padding: const EdgeInsets.only(bottom: 4),
                    itemBuilder: (context, index) {
                      final language = languages[index];
                      final selected = language == widget.language;
                      return Semantics(
                        selected: selected,
                        child: ListTile(
                          key: ValueKey('collab-code-language-$language'),
                          leading: const Icon(LucideIcons.codeXml, size: 19),
                          title: Text(language == 'PlainText' ? '纯文本' : language),
                          trailing: selected
                              ? Icon(LucideIcons.check, size: 16, color: CollabModalColors.of(context).accent)
                              : null,
                          onTap: () => Navigator.pop(context, language),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
