import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:cses_document_collab/src/model/collab_weather.dart';
import 'package:cses_document_collab/src/ui/modal/collab_color_picker.dart';
import 'package:cses_document_collab/src/ui/modal/collab_weather_visual.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_field.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_segments.dart';
import 'package:cses_document_collab/src/ui/modal/collab_switch_row.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 为借用 [context]/[editor] 中稳定 [id] 的天气卡片打开底部外观草稿面板。
/// 应由公共块菜单隔离正文输入后调用；应用一次提交修改字段，取消不写历史。
/// 锁、权限、节点或宿主变化后旧草稿永久失效；函数等待弹窗退场。
Future<void> showCollabWeatherSettings(BuildContext context, EditorState editor, String id) async {
  final node = findCollabWeather(editor, id);
  if (!context.mounted || node == null || !canEditCollabNode(editor, node)) return;
  await showCollabBottomSheet<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _WeatherSettings(editor: editor, node: node, id: id),
  );
}

/// 借用稳定节点、编辑器及其会话；状态拥有监听和未提交的属性草稿。
class _WeatherSettings extends StatefulWidget {
  /// [editor]由页面释放，[node]为打开时身份，[id]用于重排后定位。
  const _WeatherSettings({required this.editor, required this.node, required this.id});

  /// 借用的原编辑器，不由设置面板关闭。
  final EditorState editor;

  /// 原节点引用，删除后同ID重建不能复用草稿。
  final Node node;

  /// 原稳定块身份，路径变化不改变此值。
  final String id;

  /// 创建本地草稿及权限监听的所有者。
  @override
  State<_WeatherSettings> createState() => _WeatherSettingsState();
}

/// 暂存外观；观察到撤权、锁代次变化或远端属性更新后禁止迟到应用。
class _WeatherSettingsState extends State<_WeatherSettings> {
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
    final resource = CollabWeather.readAttributes(widget.node.attributes);
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
      identical(findCollabWeather(widget.editor, widget.id), widget.node) &&
      (_locks?.epoch(widget.id) ?? 0) == _epoch &&
      canEditCollabNode(widget.editor, widget.node) &&
      CollabWeather.readAttributes(widget.node.attributes).properties == _original;

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

  /// 暂存 [key] 的 [value]；null清除覆盖，保留定格天气和未触及的字段。
  /// 切回原样式恢复原宽高及字段缺省状态，中间预览不写入共享树。
  void _change(String key, Object? value) {
    if (!_current || _saving) return;
    setState(() {
      if (value == null) {
        _draft.remove(key);
      } else {
        _draft[key] = value;
      }
      if (key == 'style') {
        final card = CollabWeather(_draft);
        if (card.style == CollabWeather(_initial).style) {
          for (final field in ['style', 'width', 'height']) {
            if (_initial.containsKey(field)) {
              _draft[field] = _initial[field];
            } else {
              _draft.remove(field);
            }
          }
        } else {
          final size = weatherSize(card.style);
          _draft['width'] = size.width;
          _draft['height'] = size.height;
        }
      }
      if (key == 'date') {
        _draft.remove('frozen');
      }
      if (key == 'palette') {
        for (final color in ['fg', 'accent', 'line', 'bg']) {
          _draft.remove(color);
        }
      }
      _error = null;
    });
  }

  /// 对照打开时的属性快照一次提交变化字段；不以重新解码的Map身份误判定格数据变更。
  /// 切换固定日时先查询并与日期原子保存。
  /// 查询期间身份/权限/锁或原属性变化后丢弃结果，异常留在面板并报告。
  Future<void> _save() async {
    if (!_current || _saving) return;
    final before = _initial;
    final changes = <String, Object?>{
      for (final key in collabWeatherKeys)
        if (_draft[key] != before[key] || _draft.containsKey(key) != before.containsKey(key))
          key: _draft[key],
    };
    if (changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      final date = CollabWeather(_draft).date;
      final loader = EditorCommandContext.of(widget.editor).services.loadWeather;
      if (changes.containsKey('date') && date != null && loader != null) {
        final data = await loader(date: date, refresh: false, cancelled: () => !mounted || !_current);
        if (!mounted || !_current) return;
        changes['frozen'] = data.toJson();
      }
      if (!_current) return;
      _applying = true;
      final saved = await changeCollabWeatherProperties(widget.editor, widget.id, changes);
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
          '天气设置保存失败',
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
    final styles = collabWeatherLayouts.keys.toList();
    final index = styles.indexOf(CollabWeather(_draft).style);
    _change('style', styles[(index + direction) % styles.length]);
  }

  /// 在借用 [context] 内固定展示 [card]，左右按钮循环切换；[enabled]控制草稿交互。
  /// 实际卡片居中，名称位于其下；短视口或键盘场景缩小预览，给设置滚动区保留空间。
  Widget _previewHeader(BuildContext context, CollabWeather card, bool enabled) {
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
      key: const ValueKey('weather-settings-header'),
      padding: EdgeInsets.fromLTRB(20, compact ? 0 : 4, 20, compact ? 4 : 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('weather-style-previous'),
                tooltip: '上一个样式',
                constraints: BoxConstraints.tightFor(width: buttonSize, height: buttonSize),
                padding: EdgeInsets.zero,
                onPressed: enabled ? () => _stepStyle(-1) : null,
                icon: Icon(LucideIcons.chevronLeft, color: enabled ? colors.accent : colors.muted),
              ),
              Expanded(
                child: SizedBox(
                  key: const ValueKey('weather-settings-preview'),
                  height: previewHeight,
                  child: CollabWeatherVisual(card: card, weather: card.frozen, alignment: Alignment.center),
                ),
              ),
              IconButton(
                key: const ValueKey('weather-style-next'),
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
              collabWeatherLayouts[card.style]!.label,
              key: const ValueKey('weather-style-name'),
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
    final card = CollabWeather(_draft);
    final enabled = _current && !_saving;
    return CollabBottomSheet(
      key: const ValueKey('weather-settings-sheet'),
      title: const Text('天气设置'),
      icon: LucideIcons.cloudSun,
      canClose: !_saving,
      expand: true,
      header: _previewHeader(context, card, enabled),
      scrollKey: const ValueKey('weather-settings-content'),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          key: const ValueKey('weather-apply'),
          onPressed: enabled ? _save : null,
          child: const Text('应用'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CollabModalField(
            label: '时间锚点',
            child: CollabModalSegments<String>(
              values: const {'fixed': '定格日期', 'live': '实时天气'},
              selected: card.date == null ? 'live' : 'fixed',
              onSelected: enabled
                  ? (value) => _change(
                      'date',
                      value == 'live'
                          ? 'live'
                          : CollabWeather(CollabWeather.readAttributes(widget.node.attributes).values).date ??
                                weatherDay(DateTime.now()),
                    )
                  : null,
            ),
          ),
          CollabModalField(
            label: '色调',
            child: CollabModalSegments<String>(
              values: {for (final entry in collabWeatherPalettes.entries) entry.key: entry.value.$1},
              selected: _draft['palette'] as String? ?? 'document',
              onSelected: enabled ? (value) => _change('palette', value) : null,
            ),
          ),
          CollabModalField(
            label: '图标颜色',
            child: CollabModalSegments<String>(
              values: const {'original': '天气原色', 'mono': '随强调色'},
              selected: _draft['iconMode'] as String? ?? 'original',
              onSelected: enabled ? (value) => _change('iconMode', value) : null,
            ),
          ),
          CollabSwitchRow(
            title: const Text('显示高低温'),
            value: _draft['range'] != 'off',
            onChanged: enabled && card.style != 'classic'
                ? (value) => _change('range', value ? 'on' : 'off')
                : null,
          ),
          CollabSwitchRow(
            title: const Text('透明底色'),
            value:
                _draft['bg'] == 'transparent' ||
                (!_draft.containsKey('bg') && (_draft['palette'] == null || _draft['palette'] == 'document')),
            onChanged: enabled
                ? (value) => _change(
                    'bg',
                    value
                        ? 'transparent'
                        : (_draft['palette'] == null || _draft['palette'] == 'document')
                        ? '#ffffff'
                        : null,
                  )
                : null,
          ),
          for (final entry in {
            'fg': '文字颜色',
            'accent': '强调颜色',
            'line': '线条颜色',
            'bg': '背景颜色',
            'bc': '边框颜色',
          }.entries)
            CollabModalField(
              label: entry.value,
              child: CollabColorPicker(
                keyPrefix: 'weather-${entry.key}',
                selection: CollabColorSelection(
                  _draft[entry.key] is String ? _draft[entry.key] as String : null,
                ),
                enabled: enabled,
                textColors: entry.key == 'fg',
                resetLabel: '跟随样式',
                onSelected: (value) async => _change(entry.key, value),
              ),
            ),
          CollabModalField(
            label: '边框',
            child: CollabModalSegments<String>(
              values: collabWeatherBorders,
              selected: _draft['bw'] is String ? _draft['bw'] as String : '0px solid',
              onSelected: enabled ? (value) => _change('bw', value) : null,
            ),
          ),
          TextButton(
            onPressed: enabled
                ? () {
                    for (final key in ['fg', 'accent', 'line', 'bg', 'bc']) {
                      _change(key, null);
                    }
                  }
                : null,
            child: const Text('恢复默认颜色'),
          ),
          if (!_current) const Text('内容或权限已变化，请关闭后重新打开'),
          if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    );
  }
}
