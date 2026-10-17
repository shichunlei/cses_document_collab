import 'dart:convert';

import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:flutter/material.dart';

/// 共用的常用表情目录；条目为原生 Unicode 和可搜索的中英文名称。
/// 分类只影响选择界面，不写入正文；目录外的组合表情可通过粘贴使用。
const collabEmojiGroups = <String, List<(String, String)>>{
  '常用': [
    ('💡', '灵感 灯泡 idea'),
    ('📢', '通知 广播 announcement'),
    ('😀', '笑脸 smile'),
    ('📝', '笔记 memo'),
    ('✅', '完成 对勾 check'),
    ('⚠️', '警告 warning'),
    ('❗', '重要 感叹号 important'),
    ('⭐', '星星 star'),
    ('🎯', '目标 target'),
    ('🔥', '火 热门 fire'),
    ('❤️', '爱心 heart'),
    ('🚀', '火箭 rocket'),
    ('📌', '固定 图钉 pin'),
    ('💬', '讨论 气泡 chat'),
    ('🎉', '庆祝 party'),
    ('📄', '文档 document'),
    ('📚', '书籍 books'),
    ('🌈', '彩虹 rainbow'),
  ],
  '表情与手势': [
    ('😘', '亲吻 kiss'),
    ('🤪', '鬼脸 crazy'),
    ('😊', '微笑 happy'),
    ('😂', '笑哭 laugh'),
    ('🤔', '思考 think'),
    ('🥳', '庆祝 celebrate'),
    ('😎', '酷 cool'),
    ('😍', '喜欢 love'),
    ('😢', '伤心 sad'),
    ('😭', '哭泣 cry'),
    ('😴', '睡觉 sleep'),
    ('🤝', '握手 handshake'),
    ('👍', '赞 like'),
    ('👏', '鼓掌 clap'),
    ('🙌', '欢呼 hooray'),
    ('🙏', '感谢 thanks'),
  ],
  '自然与生活': [
    ('🌱', '成长 幼苗 grow'),
    ('🌳', '树 tree'),
    ('🌸', '花 flower'),
    ('☀️', '太阳 sun'),
    ('🌙', '月亮 moon'),
    ('🌍', '地球 earth'),
    ('🐱', '猫 cat'),
    ('🐶', '狗 dog'),
    ('🍀', '幸运 luck'),
    ('🍎', '苹果 apple'),
    ('☕', '咖啡 coffee'),
    ('🎂', '生日 蛋糕 cake'),
  ],
  '工作与符号': [
    ('📅', '日历 calendar'),
    ('📊', '图表 chart'),
    ('📋', '清单 list'),
    ('📁', '文件夹 folder'),
    ('💻', '电脑 computer'),
    ('🔍', '搜索 search'),
    ('🔗', '链接 link'),
    ('🔒', '锁 lock'),
    ('🛠️', '工具 tools'),
    ('⏰', '闹钟 clock'),
    ('🏆', '奖杯 trophy'),
    ('🎨', '艺术 art'),
    ('❓', '问题 question'),
    ('❌', '错误 cross'),
    ('⭕', '圆圈 circle'),
    ('💯', '满分 hundred'),
  ],
};

/// 文档图标与高亮块共用的表情选择器；保存原生 Unicode，支持搜索、分类及粘贴。
/// 最近使用仅在当前进程内缓存最多12个原生表情，不含文档、账号和网络资料。
/// 父级拥有保存和权限，本组件拥有并释放搜索输入控制器。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/editor/collab_emoji_picker.dart';
/// final picker = CollabEmojiPicker(keyPrefix: 'icon-emoji',
///   current: '💡', onSelected: (value) async { /* 保存原生表情 */ });
/// ```
class CollabEmojiPicker extends StatefulWidget {
  /// [key] 控制身份与状态复用；[keyPrefix] 标识搜索和表情按钮。
  /// [current] 为已有原文，目录外的组合表情也会显示；[onSelected] 等待所属保存动作。
  /// [enabled] 默认 true；[onClear] 非空才提供移除，由父级决定空串或元数据清除语义。
  const CollabEmojiPicker({
    super.key,
    required this.keyPrefix,
    required this.onSelected,
    this.current,
    this.enabled = true,
    this.onClear,
  });

  /// 必填稳定前缀，单个表情按钮为 keyPrefix-Unicode。
  final String keyPrefix;

  /// 当前原生表情或历史前缀；null 表示未设置，不自动选择默认项。
  final String? current;

  /// 必填保存回调；父级在调用时重新核对权限与稳定文档身份。
  final Future<void> Function(String value) onSelected;

  /// 是否可编辑，默认 true；保存期间禁止重复选择。
  final bool enabled;

  /// 可选移除回调，null 隐藏移除入口，便于宿主保留自己的移除按钮。
  final Future<void> Function()? onClear;

  /// 创建拥有搜索输入的状态，不创建文档、连接或订阅。
  @override
  State<CollabEmojiPicker> createState() => _CollabEmojiPickerState();
}

/// 目录和缓存均无异步资源；仅在明确选择成功后记录最近使用。
class _CollabEmojiPickerState extends State<CollabEmojiPicker> {
  /// 进程内有界表情缓存，不存账号信息，不需要持久化或外部释放。
  static final List<String> _recent = [];

  /// 本组件创建的搜索控制器，销毁时释放，不借用正文输入连接。
  final TextEditingController _search = TextEditingController();
  String _category = '常用';
  bool _saving = false;

  /// 释放本组件创建的输入控制器。
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// 保存 [value]，null 调用移除；最多32个字素/256 UTF-8字节，不截断组合表情。
  /// 保存异常可见并允许重试，面板关闭后不刷新局部状态。
  Future<void> _select(String? value) async {
    if (!widget.enabled || _saving) return;
    if (value != null &&
        (value.trim().isEmpty ||
            value.characters.length > 32 ||
            utf8.encode(value).length > 256)) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('表情或前缀过长，请缩短后重试')));
      return;
    }
    setState(() => _saving = true);
    try {
      if (value == null) {
        await widget.onClear?.call();
      } else {
        await widget.onSelected(value);
        _recent.remove(value);
        _recent.insert(0, value);
        if (_recent.length > 12) _recent.removeLast();
      }
    } catch (error, stack) {
      CollabDiagnostics.report(
        '表情设置失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('表情设置失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 按 [context] 约束自动换行展示目录；搜索匹配全目录，粘贴始终保留完整原文。
  /// 配置移除回调时以共用危险操作红色展示入口。
  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final enabled = widget.enabled && !_saving;
    final recent = query.isEmpty ? _recent : const <String>[];
    final entries =
        (query.isEmpty
                ? collabEmojiGroups[_category]!
                : collabEmojiGroups.values
                      .expand((items) => items)
                      .where(
                        (entry) =>
                            entry.$1.contains(query) ||
                            entry.$2.toLowerCase().contains(query),
                      ))
            .where((entry) => !recent.contains(entry.$1))
            .toList();
    final current = widget.current;
    final displayed = {...entries.map((entry) => entry.$1), ...recent};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: ValueKey('${widget.keyPrefix}-search'),
          controller: _search,
          enabled: enabled,
          decoration: const InputDecoration(
            hintText: '搜索或粘贴表情',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (value) async => _select(value.trim()),
        ),
        if (query.isNotEmpty)
          TextButton(
            key: ValueKey('${widget.keyPrefix}-apply'),
            onPressed: enabled
                ? () async => _select(_search.text.trim())
                : null,
            child: Text('使用“${_search.text.trim()}”'),
          ),
        const SizedBox(height: 8),
        if (query.isEmpty) ...[
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final category in collabEmojiGroups.keys)
                ChoiceChip(
                  label: Text(category),
                  selected: _category == category,
                  onSelected: enabled
                      ? (_) => setState(() => _category = category)
                      : null,
                ),
            ],
          ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('最近使用'),
            Wrap(children: [for (final value in recent) _button(value, value)]),
          ],
        ],
        if (current != null &&
            current.isNotEmpty &&
            !displayed.contains(current)) ...[
          const SizedBox(height: 8),
          const Text('当前'),
          Wrap(children: [_button(current, '当前 $current')]),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [for (final entry in entries) _button(entry.$1, entry.$2)],
        ),
        if (widget.onClear != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('${widget.keyPrefix}-clear'),
              style: TextButton.styleFrom(
                foregroundColor: CollabModalColors.of(context).danger,
              ),
              onPressed: enabled ? () async => _select(null) : null,
              child: const Text('移除'),
            ),
          ),
      ],
    );
  }

  /// 构建原生 [value] 按钮，以 [label] 提供搜索之外的可访问名称。
  Widget _button(String value, String label) => Semantics(
    selected: widget.current == value,
    child: Tooltip(
      message: label,
      child: TextButton(
        key: ValueKey('${widget.keyPrefix}-$value'),
        onPressed: widget.enabled && !_saving
            ? () async => _select(value)
            : null,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.all(4),
          side: BorderSide(
            color: widget.current == value
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
          ),
        ),
        child: Text(value, style: const TextStyle(fontSize: 24)),
      ),
    ),
  );
}
