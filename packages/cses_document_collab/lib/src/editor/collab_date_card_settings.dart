import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:cses_document_collab/src/model/collab_date_card.dart';
import 'package:cses_document_collab/src/ui/modal/collab_color_picker.dart';
import 'package:cses_document_collab/src/ui/modal/collab_date_card_visual.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_field.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_segments.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 为借用 [context]/[editor] 中稳定 [id] 的日期卡片打开底部外观草稿面板。
/// 应由公共块菜单隔离正文输入后调用；应用一次提交修改字段，取消不写历史。
/// 锁、权限、节点或宿主变化后旧草稿永久失效；函数等待弹窗退场。
Future<void> showCollabDateCardSettings(BuildContext context, EditorState editor, String id) async {
  final node = findCollabDateCard(editor, id);
  if (!context.mounted || node == null || !canEditCollabNode(editor, node)) return;
  await showCollabBottomSheet<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _DateSettings(editor: editor, node: node, id: id),
  );
}

/// 借用稳定节点、编辑器及其会话；状态拥有监听和未提交的属性草稿。
class _DateSettings extends StatefulWidget {
  /// [editor]由页面释放，[node]为打开时身份，[id]用于重排后定位。
  const _DateSettings({required this.editor, required this.node, required this.id});

  /// 借用的原编辑器，不由设置面板关闭。
  final EditorState editor;

  /// 原节点引用，删除后同ID重建不能复用草稿。
  final Node node;

  /// 原稳定块身份，路径变化不改变此值。
  final String id;

  /// 创建本地草稿及权限监听的所有者。
  @override
  State<_DateSettings> createState() => _DateSettingsState();
}

/// 暂存外观；观察到撤权、锁代次变化或远端属性更新后禁止迟到应用。
class _DateSettingsState extends State<_DateSettings> {
  /// 本面板创建的草稿副本，确认前不回写模型。
  late final Map<String, dynamic> _draft;

  /// 打开时的不可变值快照；预览切回原样式/格式时恢复作者尺寸及缺失字段。
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

  /// 校验或保存失败的用户提示，null表示无错误。
  String? _error;

  /// 初始化草稿和借用对象监听，不创建网络或原生资源。
  @override
  void initState() {
    super.initState();
    final resource = CollabDateCard.readAttributes(widget.node.attributes);
    _draft = resource.values;
    _initial = Map.unmodifiable(_draft);
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
      identical(findCollabDateCard(widget.editor, widget.id), widget.node) &&
      (_locks?.epoch(widget.id) ?? 0) == _epoch &&
      canEditCollabNode(widget.editor, widget.node) &&
      CollabDateCard.readAttributes(widget.node.attributes).properties == _original;

  /// 外部变化永久失效；自身同步提交的节点通知不作为远端冲突处理。
  void _observe() {
    if (!mounted || _saving) return;
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

  /// 暂存 [key] 的 [value]；null清除覆盖，保留定格日期和未触及的字段。
  void _change(String key, Object? value) {
    if (!_current || _saving) return;
    final previous =
        _draft[key] ??
        switch (key) {
          'style' => 'calendar',
          'format' => 'full',
          _ => null,
        };
    if (previous == value) return;
    setState(() {
      if (value == null) {
        _draft.remove(key);
      } else {
        _draft[key] = value;
      }
      if (key == 'style' || key == 'format') {
        _updateDraftSize();
      }
      _error = null;
    });
  }

  /// 按最终草稿相对于原样式/格式的差异推导尺寸，不把中间预览写入共享树。
  /// 切回原显示恢复原始宽高；仅格式变化保持原宽，实际样式变化使用新样式默认框。
  void _updateDraftSize() {
    final card = CollabDateCard(_draft);
    final original = CollabDateCard(_initial);
    if (card.style == original.style && card.format == original.format) {
      for (final key in ['width', 'height']) {
        if (_initial.containsKey(key)) {
          _draft[key] = _initial[key];
        } else {
          _draft.remove(key);
        }
      }
      return;
    }
    final size = dateCardSize(card.style, card.format);
    final rawWidth = _initial['width'];
    final width = card.style == original.style && rawWidth is num && rawWidth.isFinite && rawWidth > 0
        ? rawWidth.toDouble()
        : size.width;
    _draft['width'] = width;
    _draft['height'] = ((size.height * width / size.width) * 1000).round() / 1000;
  }

  /// 一次提交已变化字段；异常留在面板并报告，成功后关闭且不重开键盘。
  Future<void> _save() async {
    if (!_current || _saving) return;
    final before = CollabDateCard.readAttributes(widget.node.attributes).values;
    final changes = <String, Object?>{
      for (final key in collabDateCardKeys)
        if (_draft[key] != before[key] || _draft.containsKey(key) != before.containsKey(key)) key: _draft[key],
    };
    if (changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await changeCollabDateCardProperties(widget.editor, widget.id, changes);
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop();
      } else {
        setState(() => _error = '内容或权限已变化，请关闭后重新打开');
      }
    } catch (error, stack) {
      if (!widget.editor.isDisposed) {
        EditorCommandContext.report(widget.editor, '日期设置保存失败', error: error, stackTrace: stack, tag: 'DocCollab');
      }
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 沿用桌面格式显隐，隐藏层级的字号草稿保留以便切回完整格式。
  bool get _secondaryVisible {
    final card = CollabDateCard(_draft);
    if ({'masthead', 'split'}.contains(card.style)) return true;
    if ({'calendar', 'banner', 'rail'}.contains(card.style)) return card.format != 'min';
    return card.format == 'full';
  }

  /// 读取当前样式的 [role]（0日号、1主行、2副行）设计字号；坏值仅展示回落。
  double _fontSize(int role) {
    final spec = collabDateCardDesigns[CollabDateCard(_draft).style]!;
    final raw = '${_draft[spec.fontKey] ?? ''}'.trim().split(RegExp(r'\s+'));
    final size = role < raw.length ? double.tryParse(raw[role]) : null;
    return size != null && size.isFinite && size > 0 ? size : spec.fonts[role];
  }

  /// 读取 [role] 的文档显示字号，保留一位小数；排除手机视口的适配缩放。
  /// 异常大值不参与乘十取整，避免读取历史数据时发生数值溢出。
  double _displayFontSize(int role) {
    final size = _fontSize(role) * CollabDateCard(_draft).contentScale;
    if (!size.isFinite) return collabDateCardDesigns[CollabDateCard(_draft).style]!.fonts[role];
    return (size * 10).isFinite ? (size * 10).round() / 10 : size;
  }

  /// 暂存当前样式 [role] 的显示字号 [size]，除以内容倍率后保存设计像素。
  /// 设计值按桌面规则保留两位小数，默认值用-占位，省略尾部默认。
  void _changeFont(int role, double size) {
    final spec = collabDateCardDesigns[CollabDateCard(_draft).style]!;
    final scaled = size / CollabDateCard(_draft).contentScale * 100;
    if (!scaled.isFinite || scaled <= 0) return;
    final designSize = scaled.round() / 100;
    final values = [for (var i = 0; i < 3; i++) i == role ? designSize : _fontSize(i)];
    final encoded = [for (var i = 0; i < 3; i++) values[i] == spec.fonts[i] ? '-' : values[i].toString()];
    while (encoded.isNotEmpty && encoded.last == '-') {
      encoded.removeLast();
    }
    _change(spec.fontKey, encoded.isEmpty ? null : encoded.join(' '));
  }

  /// 按 [direction] 循环切换样式：-1为上一个，1为下一个；仅修改本地草稿。
  /// 无效会话和保存期间忽略操作，原样式的尺寸恢复仍由统一草稿命令负责。
  void _stepStyle(int direction) {
    if (!_current || _saving) return;
    final styles = collabDateCardStyles.keys.toList();
    final index = styles.indexOf(CollabDateCard(_draft).style);
    _change('style', styles[(index + direction) % styles.length]);
  }

  /// 在借用 [context] 内固定展示 [card]，左右按钮循环切换；[enabled]控制草稿交互。
  /// 实际卡片居中，名称位于其下；短视口或键盘场景缩小预览，给设置滚动区保留空间。
  Widget _previewHeader(BuildContext context, CollabDateCard card, bool enabled) {
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
      key: const ValueKey('date-card-settings-header'),
      padding: EdgeInsets.fromLTRB(20, compact ? 0 : 4, 20, compact ? 4 : 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('date-card-style-previous'),
                tooltip: '上一个样式',
                constraints: BoxConstraints.tightFor(width: buttonSize, height: buttonSize),
                padding: EdgeInsets.zero,
                onPressed: enabled ? () => _stepStyle(-1) : null,
                icon: Icon(LucideIcons.chevronLeft, color: enabled ? colors.accent : colors.muted),
              ),
              Expanded(
                child: SizedBox(
                  key: const ValueKey('date-card-settings-preview'),
                  height: previewHeight,
                  child: CollabDateCardVisual(card: card, alignment: Alignment.center),
                ),
              ),
              IconButton(
                key: const ValueKey('date-card-style-next'),
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
              collabDateCardStyles[card.style]!,
              key: const ValueKey('date-card-style-name'),
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
                  for (final entry in entries.skip(start).take(columns)) entry.key: ValueKey('$keyPrefix${entry.key}'),
              },
              onSelected: onSelected,
            ),
          ],
        ],
      );
    },
  );

  /// 在借用 [context] 中组合公共底部面板；预览、切换按钮和名称固定，设置区独立滚动。
  @override
  Widget build(BuildContext context) {
    final card = CollabDateCard(_draft);
    final enabled = _current && !_saving;
    return CollabBottomSheet(
      key: const ValueKey('date-card-settings-sheet'),
      title: const Text('日期设置'),
      icon: LucideIcons.calendarDays,
      canClose: !_saving,
      expand: true,
      header: _previewHeader(context, card, enabled),
      scrollKey: const ValueKey('date-card-settings-content'),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          key: const ValueKey('date-card-apply'),
          onPressed: enabled ? _save : null,
          child: const Text('应用'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CollabModalField(
            label: '显示内容',
            child: _options<String>(
              context,
              collabDateCardFormats,
              card.format,
              enabled ? (value) => _change('format', value) : null,
            ),
          ),
          CollabModalField(
            label: '字体',
            child: _options<String>(
              context,
              const {'': '跟随文档', 'sans': '系统默认', 'serif': '衬线', 'kai': '楷体', 'mono': '等宽'},
              _draft['ff'] is String ? _draft['ff'] as String : '',
              enabled ? (value) => _change('ff', value.isEmpty ? null : value) : null,
            ),
          ),
          for (final role in [0, 1, if (_secondaryVisible) 2])
            CollabModalField(
              label: ['日期字号', '主行字号', '副行字号'][role],
              child: _options<double>(
                context,
                {
                  for (final size in [12.0, 16.0, 24.0, 32.0, 48.0, 64.0]) size: size.toInt().toString(),
                },
                _displayFontSize(role),
                enabled ? (size) => _changeFont(role, size) : null,
                keyPrefix: 'date-card-font-$role-',
              ),
            ),
          TextButton(
            onPressed: enabled ? () => _change(collabDateCardDesigns[card.style]!.fontKey, null) : null,
            child: const Text('恢复当前样式字号'),
          ),
          for (final entry in {'fg': '文字颜色', 'bg': '背景颜色', 'bc': '边框颜色'}.entries)
            CollabModalField(
              label: entry.value,
              child: CollabColorPicker(
                keyPrefix: 'date-card-${entry.key}',
                selection: CollabColorSelection(_draft[entry.key] is String ? _draft[entry.key] as String : null),
                enabled: enabled,
                textColors: entry.key == 'fg',
                resetLabel: '跟随样式',
                onSelected: (value) async => _change(entry.key, value),
              ),
            ),
          CollabModalField(
            label: '边框',
            child: _options<String>(
              context,
              collabDateCardBorders,
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
}
