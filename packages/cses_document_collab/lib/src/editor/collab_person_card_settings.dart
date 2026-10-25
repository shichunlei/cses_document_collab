import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:cses_document_collab/src/model/collab_person_card.dart';
import 'package:cses_document_collab/src/ui/modal/collab_color_picker.dart';
import 'package:cses_document_collab/src/ui/modal/collab_person_card_visual.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_field.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_segments.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 为借用 [context]/[editor] 中稳定 [id] 的人员卡片打开底部外观草稿面板。
/// 应由公共块菜单隔离正文输入后调用；应用一次提交修改字段，取消不写历史。
/// 锁、权限、节点或宿主变化后旧草稿永久失效；函数等待弹窗退场。
Future<void> showCollabPersonCardSettings(BuildContext context, EditorState editor, String id) async {
  final node = findCollabPersonCard(editor, id);
  if (!context.mounted || node == null || !canEditCollabNode(editor, node)) return;
  await showCollabBottomSheet<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _PersonCardSettings(editor: editor, node: node, id: id),
  );
}

/// 借用稳定节点、编辑器及其会话；状态拥有监听和未提交的属性草稿。
class _PersonCardSettings extends StatefulWidget {
  /// [editor]由页面释放，[node]为打开时身份，[id]用于重排后定位。
  const _PersonCardSettings({required this.editor, required this.node, required this.id});

  /// 借用的原编辑器，不由设置面板关闭。
  final EditorState editor;

  /// 原节点引用，删除后同ID重建不能复用草稿。
  final Node node;

  /// 原稳定块身份，路径变化不改变此值。
  final String id;

  /// 创建本地草稿及权限监听的所有者。
  @override
  State<_PersonCardSettings> createState() => _PersonCardSettingsState();
}

/// 暂存外观；观察到撤权、锁代次变化或远端属性更新后禁止迟到应用。
class _PersonCardSettingsState extends State<_PersonCardSettings> {
  /// 本面板创建的草稿副本，确认前不回写模型。
  late final Map<String, dynamic> _draft;

  /// 打开时的独立属性快照；切回原样式时恢复作者尺寸与缺省字段。
  late final Map<String, dynamic> _initial;

  /// 打开时规范化属性串，用于阻止覆盖远端更新。
  late final String _original;

  /// 捕获原宿主和锁服务身份，防止跨文档结果回写。
  late final Object _services;

  /// 打开时借用的锁服务，dispose只解绑监听。
  late final CollabBlockLocks? _locks;

  /// 原块及其祖先锁的版本，变化后不恢复旧会话。
  late final int _epoch;

  /// 已经观察到权限、锁、目标或外部属性失效。
  bool _invalid = false;

  /// 应用期间阻止重复操作与关闭。
  bool _saving = false;

  /// 仅同步提交自身事务时忽略节点回调；查询等待仍须闩锁权限/锁失效。
  bool _applying = false;

  /// 校验或保存失败的用户提示，null表示无错误。
  String? _error;

  /// 初始化草稿和借用对象监听，不创建网络或原生资源。
  @override
  void initState() {
    super.initState();
    final resource = CollabPersonCard.readAttributes(widget.node.attributes);
    _draft = resource.values;
    _initial = Map<String, dynamic>.from(_draft);
    _original = resource.properties;
    _services = EditorCommandContext.of(widget.editor).services;
    _locks = CollabBlockLocks.of(widget.editor);
    _epoch = _locks?.epoch(widget.id) ?? 0;
    widget.editor.editableNotifier.addListener(_observe);
    widget.node.addListener(_observe);
    widget.editor.document.root.addListener(_observe);
    _locks?.addListener(_observe);
  }

  /// 同步核对原宿主、节点身份、全部外观快照、权限及锁代次。
  bool get _current =>
      !_invalid &&
      !widget.editor.isDisposed &&
      widget.editor.editable &&
      identical(EditorCommandContext.of(widget.editor).services, _services) &&
      identical(CollabBlockLocks.of(widget.editor), _locks) &&
      identical(findCollabPersonCard(widget.editor, widget.id), widget.node) &&
      (_locks?.epoch(widget.id) ?? 0) == _epoch &&
      canEditCollabNode(widget.editor, widget.node) &&
      CollabPersonCard.readAttributes(widget.node.attributes).properties == _original;

  /// 外部变化永久失效；自身同步提交的节点通知不作为远端冲突处理。
  void _observe() {
    if (!mounted || _applying) return;
    if (!_current) _invalid = true;
    setState(() {});
  }

  /// 解绑全部借用监听，不释放编辑器、节点或锁服务。
  @override
  void dispose() {
    widget.editor.editableNotifier.removeListener(_observe);
    widget.node.removeListener(_observe);
    widget.editor.document.root.removeListener(_observe);
    _locks?.removeListener(_observe);
    super.dispose();
  }

  /// 暂存[key]的[value]；切换样式保留内容尺度和字号，切回原样式恢复原宽高及缺省字段。
  void _change(String key, Object? value) {
    if (!_current || _saving) return;
    setState(() {
      final scale = CollabPersonCard(_draft).contentScale;
      if (value == null) {
        _draft.remove(key);
      } else {
        _draft[key] = value;
      }
      if (key == 'style') {
        final card = CollabPersonCard(_draft);
        if (card.style == CollabPersonCard(_initial).style) {
          for (final field in ['style', 'width', 'height', 'sc']) {
            if (_initial.containsKey(field)) {
              _draft[field] = _initial[field];
            } else {
              _draft.remove(field);
            }
          }
        } else {
          final size = personCardSize(card.style, scale: scale);
          _draft.addAll({'width': size.width, 'height': size.height, 'sc': (scale * 100).round() / 100});
        }
      }
      _error = null;
    });
  }

  /// 对照打开时的属性快照一次提交变化字段；不以重新解码的Map身份误判定格数据变更。
  /// 身份/权限/锁或原属性变化后丢弃结果，异常留在面板并报告。
  Future<void> _save() async {
    if (!_current || _saving) return;
    final before = _initial;
    final changes = <String, Object?>{
      for (final key in collabPersonCardKeys)
        if (_draft[key] != before[key] || _draft.containsKey(key) != before.containsKey(key))
          key: _draft[key],
    };
    if (changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      if (!_current) return;
      _applying = true;
      final saved = await changeCollabPersonCardProperties(widget.editor, widget.id, changes);
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop();
      } else {
        setState(() => _error = '内容或权限已变化，请关闭后重新打开');
      }
    } catch (error, stack) {
      if (!widget.editor.isDisposed) {
        EditorCommandContext.report(
          widget.editor,
          '人员设置保存失败',
          error: error,
          stackTrace: stack,
          tag: 'DocCollab',
        );
      }
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      _applying = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 按 [direction] 循环切换样式：-1为上一个，1为下一个；仅修改本地草稿。
  /// 无效会话和保存期间忽略操作，原样式的尺寸恢复仍由统一草稿命令负责。
  void _stepStyle(int direction) {
    if (!_current || _saving) return;
    final styles = collabPersonCardStyles.keys.toList();
    final index = styles.indexOf(CollabPersonCard(_draft).style);
    _change('style', styles[(index + direction) % styles.length]);
  }

  /// 在借用 [context] 内固定展示 [card]，左右按钮循环切换；[enabled]控制草稿交互。
  /// 实际卡片居中，名称位于其下；短视口或键盘场景缩小预览，给设置滚动区保留空间。
  Widget _previewHeader(BuildContext context, CollabPersonCard card, bool enabled) {
    final media = MediaQuery.of(context);
    final available = media.size.height * .9 - media.viewInsets.bottom;
    final compact = available < 360;
    final previewHeight = available < 260
        ? 32.0
        : compact
        ? 80.0
        : 160.0;
    final buttonSize = compact ? 32.0 : 44.0;
    final colors = CollabModalColors.of(context);
    return Padding(
      key: const ValueKey('person-card-settings-header'),
      padding: EdgeInsets.fromLTRB(20, compact ? 0 : 4, 20, compact ? 4 : 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('person-card-style-previous'),
                tooltip: '上一个样式',
                constraints: BoxConstraints.tightFor(width: buttonSize, height: buttonSize),
                padding: EdgeInsets.zero,
                onPressed: enabled ? () => _stepStyle(-1) : null,
                icon: Icon(LucideIcons.chevronLeft, color: enabled ? colors.accent : colors.muted),
              ),
              Expanded(
                child: SizedBox(
                  key: const ValueKey('person-card-settings-preview'),
                  height: previewHeight,
                  child: CollabPersonCardVisual(card: card, alignment: Alignment.center),
                ),
              ),
              IconButton(
                key: const ValueKey('person-card-style-next'),
                tooltip: '下一个样式',
                constraints: BoxConstraints.tightFor(width: buttonSize, height: buttonSize),
                padding: EdgeInsets.zero,
                onPressed: enabled ? () => _stepStyle(1) : null,
                icon: Icon(LucideIcons.chevronRight, color: enabled ? colors.accent : colors.muted),
              ),
            ],
          ),
          SizedBox(height: compact ? 2 : 6),
          Semantics(
            liveRegion: true,
            child: Text(
              collabPersonCardStyles[card.style]!,
              key: const ValueKey('person-card-style-name'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: compact ? 12 : 14,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 在借用 [context] 中组合公共底部面板；预览、切换箭头及名称固定，设置内容独立滚动。
  @override
  Widget build(BuildContext context) {
    final card = CollabPersonCard(_draft);
    final enabled = _current && !_saving;
    return CollabBottomSheet(
      key: const ValueKey('person-card-settings-sheet'),
      title: const Text('人员设置'),
      icon: LucideIcons.userRound,
      canClose: !_saving,
      expand: true,
      header: _previewHeader(context, card, enabled),
      scrollKey: const ValueKey('person-card-settings-content'),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          key: const ValueKey('person-card-apply'),
          onPressed: enabled ? _save : null,
          child: const Text('应用'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('人员资料在插入时定格，之后不随账号资料变化。'),
          CollabModalField(
            label: '头像形状',
            child: CollabModalSegments<String>(
              values: const {'circle': '圆形', 'rounded': '圆角'},
              selected: _draft['avatar'] is String ? _draft['avatar'] as String : 'circle',
              onSelected: enabled ? (value) => _change('avatar', value) : null,
            ),
          ),
          CollabModalField(
            label: '头像大小',
            child: CollabModalSegments<String>(
              values: const {'small': '小', 'medium': '中', 'large': '大'},
              selected: _draft['avatarSize'] is String ? _draft['avatarSize'] as String : 'medium',
              onSelected: enabled ? (value) => _change('avatarSize', value) : null,
            ),
          ),
          CollabModalField(
            label: '部门/职务',
            child: _options<String>(
              context,
              collabPersonCardDepartments,
              _draft['dept'] is String ? _draft['dept'] as String : 'off',
              enabled ? (value) => _change('dept', value) : null,
            ),
          ),
          for (var role = 0; role < card.fonts.length; role++)
            CollabModalField(
              label: role == 0
                  ? '姓名字号'
                  : card.style == 'rowPinyin' && role == 1
                  ? '拼音字号'
                  : '部门字号',
              child: _options<double>(
                context,
                {
                  for (final size in <double>{
                    10,
                    12,
                    14,
                    16,
                    20,
                    24,
                    32,
                    double.parse((card.fonts[role] * card.contentScale).toStringAsFixed(1)),
                  })
                    size: '$size',
                },
                double.parse((card.fonts[role] * card.contentScale).toStringAsFixed(1)),
                enabled ? (value) => _font(role, value) : null,
              ),
            ),
          TextButton(
            onPressed: enabled ? () => _change(card.fontKey, null) : null,
            child: const Text('恢复当前样式字号'),
          ),
          for (final entry in const {'color': '文字颜色', 'bc': '边框颜色'}.entries)
            CollabModalField(
              label: entry.value,
              child: CollabColorPicker(
                keyPrefix: 'person-card-${entry.key}',
                selection: CollabColorSelection(
                  _draft[entry.key] is String ? _draft[entry.key] as String : null,
                ),
                enabled: enabled,
                textColors: true,
                resetLabel: '默认',
                onSelected: (value) async => _change(entry.key, value),
              ),
            ),
          CollabModalField(
            label: '边框',
            child: _options<String>(
              context,
              collabPersonCardBorders,
              _draft['bw'] is String ? _draft['bw'] as String : '0px solid',
              enabled ? (value) => _change('bw', value) : null,
            ),
          ),
          if (!_current) const Text('内容或权限已变化，请关闭后重新打开'),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    );
  }

  /// 将当前样式[role]的最终字号[size]换算为设计字号，保留其他角色并裁掉默认尾部。
  void _font(int role, double size) {
    final card = CollabPersonCard(_draft);
    final defaults = CollabPersonCard({'style': card.style}).fonts;
    final values = [
      for (var i = 0; i < card.fonts.length; i++)
        i == role ? (size / card.contentScale * 100).round() / 100 : card.fonts[i],
    ];
    final parts = [for (var i = 0; i < values.length; i++) values[i] == defaults[i] ? '-' : '${values[i]}'];
    while (parts.isNotEmpty && parts.last == '-') {
      parts.removeLast();
    }
    _change('sc', (card.contentScale * 100).round() / 100);
    _change(card.fontKey, parts.isEmpty ? null : parts.join(' '));
  }

  /// 按借用 [context] 的宽度和字号分行展示 [values]，保持标签和点击区域可读。
  /// [selected] 为当前值，[onSelected] 为草稿回调，null禁用；[keyPrefix]可提供稳定选项键。
  Widget _options<T>(
    BuildContext context,
    Map<T, String> values,
    T selected,
    ValueChanged<T>? onSelected, {
    String? keyPrefix,
  }) => LayoutBuilder(
    builder: (_, constraints) {
      final entries = values.entries.toList();
      final longest = entries.map((entry) => entry.value.runes.length).reduce(math.max);
      final minimumWidth = math.max(76.0, MediaQuery.textScalerOf(context).scale(12) * longest + 16);
      final maximumColumns = (constraints.maxWidth / minimumWidth).floor().clamp(1, 4);
      final rows = (entries.length / maximumColumns).ceil();
      final columns = (entries.length / rows).ceil();
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var start = 0; start < entries.length; start += columns) ...[
            if (start != 0) const SizedBox(height: 6),
            CollabModalSegments<T>(
              values: Map.fromEntries(entries.skip(start).take(columns)),
              selected: selected,
              itemKeys: {
                if (keyPrefix != null)
                  for (final entry in entries.skip(start).take(columns))
                    entry.key: ValueKey('$keyPrefix${entry.key}'),
              },
              onSelected: onSelected,
            ),
          ],
        ],
      );
    },
  );
}
