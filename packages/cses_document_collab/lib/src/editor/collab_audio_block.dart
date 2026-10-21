import 'package:provider/provider.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart' show csesEmbedUrlAttribute;
import 'package:cses_document_collab/src/editor/collab_resource_block_base.dart';
import 'package:cses_document_collab/src/editor/collab_unsupported_block.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_header.dart';
import 'package:cses_document_collab/src/ui/modal/collab_media_timeline.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';

/// 音频块的独立构建器，只接受无正文的audio资源；不拥有编辑器或播放器。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_audio_block.dart';
/// final builder = CollabAudioBlockComponentBuilder();
/// // 在 AppFlowyEditor.blockComponentBuilders['audio'] 注册。
/// ```
class CollabAudioBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建无外部资源所有权的音频构建器。
  CollabAudioBlockComponentBuilder();

  /// 要求audio类型且无正文和子块，以保持资源块的void结构。
  @override
  BlockComponentValidate get validate =>
      (node) => node.type == 'audio' && node.delta == null && node.children.isEmpty;

  /// 用借用[context]创建音频卡片；无效地址沿用保护性占位，不修改原数据。
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    final url = context.node.attributes[csesEmbedUrlAttribute] as String? ?? '';
    if (context.node.type != 'audio' || !isCollabResourceUrl('audio', url)) {
      return CollabUnsupportedBlockComponentBuilder().build(context);
    }
    return _AudioBlock(key: context.node.key, node: context.node, configuration: configuration);
  }
}

/// 音频卡片借用节点与选区基础能力，媒体控制器由播放器子组件持有。
class _AudioBlock extends CollabResourceBlock {
  /// [key]控制身份复用；[node]及[configuration]均借用编辑器配置。
  const _AudioBlock({super.key, required super.node, required super.configuration});

  /// 创建音频展示状态，不在构造时发请求或创建播放器。
  @override
  createState() => _AudioBlockState();
}

/// 将音频独有的播放区接入共同选区与事务能力，不拥有编辑器。
class _AudioBlockState extends CollabResourceBlockState<_AudioBlock> {
  /// 音频菜单和设置使用的展示名称。
  @override
  String get resourceLabel => '音频';

  /// 在借用[context]中展示名称标题栏与独立播放内容区；换源按URL重建播放器。
  @override
  Widget buildResourceCard(BuildContext context) => _AudioPlayer(
    key: ValueKey('audio:$url'),
    url: url,
    builder: (context, progress) => CollabCardFrame(
      surfaceKey: bodyKey,
      margin: const EdgeInsets.symmetric(vertical: 6),
      header: CollabCardHeader(
        leading: const Icon(LucideIcons.music2),
        title: Text(resource.string('name').isNotEmpty ? resource.string('name') : resourceLabel),
        readOnly: !editor.editable,
        more: buildResourceMore(openLabel: '在浏览器打开'),
      ),
      child: progress,
    ),
  );
}

/// Owns one audio controller. Keyed by URL so replacement disposes the old stream.
class _AudioPlayer extends StatefulWidget {
  /// [key] controls identity; [url] keys the owned player source. [builder] renders
  /// its progress and direct playback controls; callbacks stop after disposal.
  const _AudioPlayer({super.key, required this.url, required this.builder});

  /// Network source owned by this player's controller.
  final String url;

  /// Card renderer borrowing the progress widget and direct playback controls.
  final Widget Function(BuildContext, Widget) builder;

  /// 创建拥有单个播放器资源的状态。
  @override
  createState() => _AudioPlayerState();
}

/// 持有并释放音频播放器，局部进度借用控制器；换源通过Widget键重建。
class _AudioPlayerState extends State<_AudioPlayer> {
  /// 此State独占的播放器，释放前等待仍在执行的跳转。
  late final VideoPlayerController _controller;

  /// 初始化或播放操作的本地错误，不写入文档。
  String? _error;

  /// 尚未结束的跳转；控制器关闭前必须等待。
  Future<void>? _pendingSeek;

  /// 仅初始化/错误状态变化触发卡片重建，播放计时由局部监听处理。
  bool _initialized = false;

  /// 最近一次播放器错误状态，用于避免计时触发整卡重建。
  bool _hasError = false;

  /// 创建并初始化拥有的控制器，注册状态监听。
  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller.addListener(_refresh);
    unawaited(_load());
  }

  /// 仅初始化和错误状态变化更新卡片，时间与播放图标由局部监听更新。
  void _refresh() {
    final value = _controller.value;
    if (mounted && (_initialized != value.isInitialized || _hasError != value.hasError)) {
      setState(() {
        _initialized = value.isInitialized;
        _hasError = value.hasError;
      });
    }
  }

  /// 初始化播放器；失败仅在当前状态仍有效时显示错误。
  Future<void> _load() async {
    try {
      await _controller.initialize();
    } catch (_) {
      if (mounted) setState(() => _error = '音频加载失败');
    }
  }

  /// Runs [action] on the live owned controller; failures stay local to the card.
  Future<void> _act(Future<void> Function() action) async {
    if (!mounted) return;
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '音频操作失败');
    }
  }

  /// 跳转到[target]，由共用进度条处理失败提示；关闭资源须等待此Future。
  Future<void> _seek(Duration target) async {
    if (!mounted) return;
    final operation = _controller.seekTo(target);
    _pendingSeek = operation;
    try {
      await operation;
    } finally {
      if (identical(_pendingSeek, operation)) _pendingSeek = null;
    }
  }

  /// 等待当前跳转完成后释放拥有的控制器；失败记录诊断且继续尝试释放。
  Future<void> _close() async {
    try {
      await _pendingSeek;
    } catch (error, stackTrace) {
      EditorCommandContext.report(
        mounted ? context.read<EditorState>() : null,
        '音频关闭前跳转失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
    }
    try {
      await _controller.dispose();
    } catch (error, stackTrace) {
      EditorCommandContext.report(
        mounted ? context.read<EditorState>() : null,
        '音频资源释放失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
    }
  }

  /// 解除监听并关闭拥有的播放器；异步跳转完成前保留底层资源。
  @override
  void dispose() {
    _controller.removeListener(_refresh);
    unawaited(_close());
    super.dispose();
  }

  /// Renders progress and direct play/pause in borrowed [context], in both editing
  /// and preview. Keeps play/time/track slots mounted while initializing or failing;
  /// loading only replaces the track with an indeterminate animation.
  @override
  Widget build(BuildContext context) {
    final value = _controller.value;
    final failed = _error != null || value.hasError;
    final progress = Row(
      children: [
        ExcludeFocus(
          child: ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: _controller,
            builder: (context, value, _) => IconButton(
              key: const ValueKey('resource-audio-play'),
              tooltip: failed
                  ? '音频加载失败'
                  : !value.isInitialized
                  ? '音频加载中'
                  : value.isPlaying
                  ? '暂停音频'
                  : '播放音频',
              icon: Icon(
                value.isPlaying ? LucideIcons.circlePause : LucideIcons.circlePlay,
                color: const Color(0xFF5B5BD6),
              ),
              onPressed: !value.isInitialized || failed
                  ? null
                  : () => _act(value.isPlaying ? _controller.pause : _controller.play),
            ),
          ),
        ),
        Expanded(
          child: CollabMediaTimeline(
            controller: _controller,
            mediaKind: 'audio',
            onSeek: _seek,
            loading: !value.isInitialized && !failed,
            errorLabel: failed ? (_error ?? '音频加载失败') : null,
          ),
        ),
      ],
    );
    return widget.builder(context, progress);
  }
}
