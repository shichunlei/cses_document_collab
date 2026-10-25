import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_weather.dart';
import 'package:cses_document_collab/src/ui/modal/collab_weather_visual.dart';
import 'package:flutter/material.dart';

/// 天气查询与卡片的会话边界；借用编辑器、节点及宿主查询资源。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_weather_content.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:flutter/widgets.dart';
/// Widget weather(EditorState editor, Node node) => CollabWeatherContent(
///   editor: editor, node: node, id: node.id,
/// );
/// ```
class CollabWeatherContent extends StatefulWidget {
  /// [key]控制身份；[editor]/[node]由调用方释放，[id]是稳定协同块身份。
  const CollabWeatherContent({super.key, required this.editor, required this.node, required this.id});

  /// 借用的编辑器。
  final EditorState editor;

  /// 打开时的原节点，替换后旧请求不可写回。
  final Node node;

  /// 协同稳定身份，用于重排后定位。
  final String id;

  /// 创建请求代次和本地实时值的所有者。
  @override
  State<CollabWeatherContent> createState() => _WeatherContentState();
}

/// 请求没有持久化资源；卸载、撤权或来源变化时令迟到响应失效。
class _WeatherContentState extends State<CollabWeatherContent> {
  /// 当前请求代次；Future仍由宿主持有，取消只结束本组件的等待。
  int _generation = 0;

  /// 当前查询锚点及定格值的指纹。
  String? _signature;

  /// 当前会话借用的服务身份。
  Object? _services;

  /// 组件借用的锁服务；dispose只解除监听。
  CollabBlockLocks? _locks;

  /// 当前请求状态。
  bool _loading = false;

  /// 已成功的实时/历史查询值，不自动写入已有文档。
  CollabWeatherData? _resolved;

  /// 当前失败提示。
  String? _error;

  /// 绑定权限和节点变化；首次请求推迟到当前构建结束。
  @override
  void initState() {
    super.initState();
    _locks = CollabBlockLocks.of(widget.editor);
    widget.node.addListener(_observe);
    widget.editor.editableNotifier.addListener(_observe);
    _locks?.addListener(_observe);
    scheduleMicrotask(_observe);
  }

  /// 原节点仍存在且编辑器未关闭时才允许响应影响本组件。
  bool get _alive =>
      mounted &&
      !widget.editor.isDisposed &&
      identical(findCollabWeather(widget.editor, widget.id), widget.node);

  /// 源属性变化清除实时值；权限变化终止当前等待，恢复权限不会恢复旧请求。
  void _observe() {
    if (!_alive) {
      _generation++;
      return;
    }
    final card = CollabWeather(CollabWeather.readAttributes(widget.node.attributes).values);
    final signature = '${card.date}|${widget.node.attributes[weatherPropertyAttribute('frozen')]}';
    final services = EditorCommandContext.of(widget.editor).services;
    if (_signature != signature || !identical(_services, services)) {
      _signature = signature;
      _services = services;
      _generation++;
      _resolved = null;
      _error = null;
      _loading = false;
      if (card.frozen == null && services.loadWeather != null) unawaited(_load(refresh: false));
    } else if (!canEditCollabNode(widget.editor, widget.node) && _loading) {
      _generation++;
      _loading = false;
    }
    if (mounted) setState(() {});
  }

  /// 查询真实天气；[refresh]主动刷新固定日时一次提交frozen且可撤销。
  /// 自动查询缺失定格值只在本地展示，避免初始化占用用户的撤销历史。
  Future<void> _load({required bool refresh}) async {
    if (!_alive || _loading) return;
    final services = EditorCommandContext.of(widget.editor).services;
    final loader = services.loadWeather;
    if (loader == null || (refresh && !canEditCollabNode(widget.editor, widget.node))) return;
    final card = CollabWeather(CollabWeather.readAttributes(widget.node.attributes).values);
    final original = CollabWeather.readAttributes(widget.node.attributes).properties;
    final epoch = _locks?.epoch(widget.id) ?? 0;
    final generation = ++_generation;

    /// 当前请求的权限/身份失效时永久丢弃，由宿主按需结束共享请求等待。
    bool cancelled() =>
        !_alive ||
        generation != _generation ||
        !identical(EditorCommandContext.of(widget.editor).services, services) ||
        (refresh &&
            (!canEditCollabNode(widget.editor, widget.node) || (_locks?.epoch(widget.id) ?? 0) != epoch)) ||
        CollabWeather.readAttributes(widget.node.attributes).properties != original;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await loader(date: card.date, refresh: refresh, cancelled: cancelled);
      if (cancelled()) return;
      if (!isValidWeatherProperty('frozen', data.toJson())) throw const FormatException('天气响应无效');
      _resolved = data;
      if (refresh && card.date != null) {
        await changeCollabWeatherProperty(widget.editor, widget.id, 'frozen', data.toJson());
      }
    } catch (error, stack) {
      if (cancelled()) return;
      _error = '天气加载失败，请重试';
      EditorCommandContext.report(widget.editor, '天气加载失败', error: error, stackTrace: stack, tag: 'DocCollab');
    } finally {
      if (_alive && generation == _generation) setState(() => _loading = false);
    }
  }

  /// 只解除本组件的监听并取消结果交付，不关闭借用的编辑器或网络客户端。
  @override
  void dispose() {
    _generation++;
    widget.node.removeListener(_observe);
    widget.editor.editableNotifier.removeListener(_observe);
    _locks?.removeListener(_observe);
    super.dispose();
  }

  /// 在借用 [context] 中展示快照和刷新状态；只读或无服务时保留明确占位。
  @override
  Widget build(BuildContext context) {
    final card = CollabWeather(CollabWeather.readAttributes(widget.node.attributes).values);
    final configured = EditorCommandContext.of(widget.editor).services.loadWeather != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CollabWeatherVisual(
          card: card,
          weather: card.frozen ?? _resolved,
          status: _loading ? '加载中…' : _error,
        ),
        if (configured && canEditCollabNode(widget.editor, widget.node))
          TextButton(
            key: const ValueKey('weather-refresh'),
            onPressed: _loading ? null : () => _load(refresh: true),
            child: Text(
              _loading
                  ? '刷新中…'
                  : _error == null
                  ? '刷新天气'
                  : '重试天气',
            ),
          ),
        if (!configured && card.frozen == null) const Text('当前实例未提供天气服务'),
      ],
    );
  }
}
