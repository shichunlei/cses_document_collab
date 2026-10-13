import 'dart:math' as math;

import 'package:cses_mobile_collab_demo/src/collab/collab_code_languages.dart';
import 'package:flutter/material.dart';

Future<String?> showCodeNameEditor(BuildContext context, String name) =>
    _showCodePopover(context, _CodeNameEditor(name: name), requestFocus: true);

Future<String?> showCodeLanguagePicker(BuildContext context, String language) =>
    _showCodePopover(context, _CodeLanguagePicker(language: language));

Future<String?> _showCodePopover(
  BuildContext context,
  Widget child, {
  bool requestFocus = false,
}) {
  final box = context.findRenderObject() as RenderBox?;
  final overlay =
      Navigator.of(context).overlay?.context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return Future.value();
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return showGeneralDialog<String>(
    context: context,
    useRootNavigator: false,
    requestFocus: requestFocus,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: const Duration(milliseconds: 100),
    pageBuilder: (context, _, _) {
      final media = MediaQuery.of(context);
      return CustomSingleChildLayout(
        delegate: _CodePopoverLayout(
          anchor,
          EdgeInsets.fromLTRB(
            media.padding.left + 8,
            media.padding.top + 8,
            media.padding.right + 8,
            math.max(media.viewInsets.bottom, media.padding.bottom) + 8,
          ),
        ),
        child: Material(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 4,
          shadowColor: const Color(0x26000000),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: const BorderSide(color: Color(0xFFE1E4E8)),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      );
    },
  );
}

class _CodeNameEditor extends StatefulWidget {
  const _CodeNameEditor({required this.name});
  final String name;
  @override
  State<_CodeNameEditor> createState() => _CodeNameEditorState();
}

class _CodeNameEditorState extends State<_CodeNameEditor> {
  late final _controller = TextEditingController(
    text: widget.name,
  )..selection = TextSelection(baseOffset: 0, extentOffset: widget.name.length);

  void _save() => Navigator.of(context).pop(_controller.text.trim());
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 270,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('collab-code-name-input'),
              controller: _controller,
              autofocus: true,
              maxLength: 256,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                hintText: '输入代码块名称',
                counterText: '',
                isDense: true,
                contentPadding: EdgeInsets.all(8),
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
            ),
          ),
          const SizedBox(width: 4),
          Semantics(
            button: true,
            label: '保存代码块名称',
            child: InkWell(
              key: const ValueKey('collab-code-name-save'),
              onTap: _save,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.check, size: 18, color: Color(0xFF607D9B)),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _CodeLanguagePicker extends StatefulWidget {
  const _CodeLanguagePicker({required this.language});
  final String language;
  @override
  State<_CodeLanguagePicker> createState() => _CodeLanguagePickerState();
}

class _CodeLanguagePickerState extends State<_CodeLanguagePicker> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final languages = collabCodeLanguages.keys
        .where(
          (lang) =>
              lang.toLowerCase().contains(_query.toLowerCase()) ||
              (lang == 'PlainText' && '纯文本'.contains(_query)),
        )
        .toList();
    if (languages.remove(widget.language)) languages.insert(0, widget.language);
    return SizedBox(
      key: const ValueKey('collab-code-language-menu'),
      width: 220,
      height: 320,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              key: const ValueKey('collab-code-language-search'),
              onChanged: (value) => setState(() => _query = value),
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                hintText: '搜索语言',
                isDense: true,
                contentPadding: EdgeInsets.all(8),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: languages.isEmpty
                ? const Center(
                    child: Text('没有匹配的语言', style: TextStyle(fontSize: 13)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 4),
                    itemCount: languages.length,
                    itemBuilder: (context, index) {
                      final language = languages[index];
                      final selected = language == widget.language;
                      return Semantics(
                        selected: selected,
                        button: true,
                        child: InkWell(
                          key: ValueKey('collab-code-language-$language'),
                          onTap: () => Navigator.of(context).pop(language),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    language == 'PlainText' ? '纯文本' : language,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: selected
                                          ? const Color(0xFF5B5BD6)
                                          : const Color(0xFF374151),
                                    ),
                                  ),
                                ),
                                if (selected)
                                  const Icon(
                                    Icons.check,
                                    size: 14,
                                    color: Color(0xFF5B5BD6),
                                  ),
                              ],
                            ),
                          ),
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

class _CodePopoverLayout extends SingleChildLayoutDelegate {
  const _CodePopoverLayout(this.anchor, this.insets);
  final Rect anchor;
  final EdgeInsets insets;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.max(0, constraints.maxWidth - insets.horizontal),
          math.max(0, constraints.maxHeight - insets.vertical),
        ),
      );
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final right = math.max(
      insets.left,
      size.width - insets.right - childSize.width,
    );
    final bottom = math.max(
      insets.top,
      size.height - insets.bottom - childSize.height,
    );
    final below = anchor.bottom + 4;
    return Offset(
      anchor.left.clamp(insets.left, right),
      (below <= bottom ? below : anchor.top - childSize.height - 4).clamp(
        insets.top,
        bottom,
      ),
    );
  }

  @override
  bool shouldRelayout(_CodePopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor || insets != oldDelegate.insets;
}
