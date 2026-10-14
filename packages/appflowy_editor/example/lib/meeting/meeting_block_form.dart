import 'package:flutter/material.dart';

/// Opens the property form for a meeting [flavour].
///
/// Returns a fresh protocol props map when saved, or null when dismissed. The
/// caller owns any editor transaction that applies the returned values.
Future<Map<String, dynamic>?> showMeetingBlockForm(
  BuildContext context, {
  required String flavour,
  Map<String, dynamic> initialProps = const {},
}) => showDialog<Map<String, dynamic>>(
  context: context,
  builder: (_) =>
      _MeetingBlockForm(flavour: flavour, initialProps: initialProps),
);

/// Describes one protocol property shown in the demo form.
typedef _Field = ({
  String key,
  String label,
  bool numeric,
  bool mandatory,
  List<String>? options,
});

/// Creates a field specification for [_MeetingBlockForm].
_Field _field(
  String key,
  String label, {
  bool numeric = false,
  bool mandatory = false,
  List<String>? options,
}) => (
  key: key,
  label: label,
  numeric: numeric,
  mandatory: mandatory,
  options: options,
);

/// Lists the server-format properties editable for [flavour].
List<_Field> _fieldsFor(String flavour) => switch (flavour) {
  'image' => [
    _field('src', '图片地址', mandatory: true),
    _field('width', '原始宽度（像素）', numeric: true),
    _field('height', '原始高度（像素）', numeric: true),
  ],
  'divider' => [
    _field('text', '分割线文字'),
    _field(
      'style',
      '样式',
      options: const [
        'solid',
        'dotted',
        'dashed',
        'double',
        'tape-gradient-blocks',
        'tape-grid-pattern',
        'tape-dot-black',
        'tape-regular-lines',
        'tape-gray-lines',
      ],
    ),
    _field('size', '粗细', options: const ['thin', 'small', 'medium', 'large']),
    _field('color', '颜色（如 #26A69A）'),
    _field('align', '文字位置', options: const ['left', 'center', 'right']),
  ],
  'callout' => [
    _field('prefix', '前缀图标或文字'),
    _field('backColor', '背景色'),
    _field('color', '文字颜色'),
    _field('borderColor', '边框颜色'),
  ],
  'figma-embed' => [
    _field('url', 'Figma 链接', mandatory: true),
    _field('width', '宽度（像素）', numeric: true),
    _field('height', '高度（像素）', numeric: true),
  ],
  'juejin-embed' => [
    _field('url', '掘金链接', mandatory: true),
    _field('height', '高度（像素）', numeric: true),
  ],
  'audio' => [
    _field('name', '音频名称'),
    _field('url', '音频地址', mandatory: true),
    _field('sourceType', '来源类型'),
    _field('size', '文件大小（字节）', numeric: true),
  ],
  'video' => [
    _field('name', '视频名称'),
    _field('url', '视频地址', mandatory: true),
    _field('sourceType', '来源类型'),
    _field('type', '媒体 MIME 类型'),
    _field('width', '宽度（像素）', numeric: true),
    _field('size', '文件大小（字节）', numeric: true),
  ],
  'bookmark' => [
    _field('url', '网页地址', mandatory: true),
    _field('title', '标题'),
    _field('description', '摘要'),
    _field('icon', '图标地址'),
    _field('image', '封面地址'),
  ],
  'attachment' => [
    _field('name', '文件名称', mandatory: true),
    _field('url', '文件地址', mandatory: true),
    _field('type', '文件 MIME 类型'),
    _field('size', '文件大小（字节）', numeric: true),
    _field('icon', '文件图标标识'),
  ],
  _ => const [],
};

/// Owns text controllers while a meeting block's properties are edited.
class _MeetingBlockForm extends StatefulWidget {
  /// Creates a form for [flavour] initialized from [initialProps].
  const _MeetingBlockForm({required this.flavour, required this.initialProps});

  /// The meeting protocol flavour whose fields are displayed.
  final String flavour;

  /// Existing properties, including keys that the form does not understand.
  final Map<String, dynamic> initialProps;

  @override
  State<_MeetingBlockForm> createState() => _MeetingBlockFormState();
}

/// Validates fields and returns an updated copy of the original property map.
class _MeetingBlockFormState extends State<_MeetingBlockForm> {
  final _formKey = GlobalKey<FormState>();
  late final List<_Field> _fields = _fieldsFor(widget.flavour);
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _choices = {};

  /// Initializes each text field or choice from the existing protocol value.
  @override
  void initState() {
    super.initState();
    for (final field in _fields) {
      final value = widget.initialProps[field.key]?.toString() ?? '';
      if (field.options == null) {
        _controllers[field.key] = TextEditingController(text: value);
      } else {
        _choices[field.key] = value;
      }
    }
  }

  /// Releases controllers after the dialog route is removed.
  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Builds editable fields for every supported property in the chosen block.
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('编辑会议块'),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Form(
          key: _formKey,
          child: ListView.separated(
            itemCount: _fields.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final field = _fields[index];
              final options = field.options;
              if (options != null) {
                final current = _choices[field.key] ?? '';
                final values = <String>{
                  '',
                  ...options,
                  if (current.isNotEmpty) current,
                };
                return DropdownButtonFormField<String>(
                  initialValue: current,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: field.label),
                  items: values
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.isEmpty ? '默认' : value),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => _choices[field.key] = value ?? '',
                );
              }
              return TextFormField(
                controller: _controllers[field.key],
                decoration: InputDecoration(labelText: field.label),
                keyboardType: field.numeric
                    ? TextInputType.number
                    : TextInputType.text,
                maxLines: field.key == 'description' ? 3 : 1,
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (field.mandatory && text.isEmpty) {
                    return '请填写${field.label}';
                  }
                  if (field.numeric &&
                      text.isNotEmpty &&
                      (int.tryParse(text) == null || int.parse(text) < 0)) {
                    return '请输入非负整数';
                  }
                  return null;
                },
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  /// Validates typed values and returns props while retaining unknown keys.
  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final output = Map<String, dynamic>.from(widget.initialProps);
    for (final field in _fields) {
      final text = (_controllers[field.key]?.text ?? _choices[field.key] ?? '')
          .trim();
      if (text.isEmpty) {
        output.remove(field.key);
      } else {
        output[field.key] = field.numeric ? int.parse(text) : text;
      }
    }
    Navigator.pop(context, output);
  }
}
