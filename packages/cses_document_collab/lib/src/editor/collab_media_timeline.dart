import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 音视频共用的局部播放进度；借用控制器，不修改编辑器选区或文档内容。
///
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_media_timeline.dart';
/// import 'package:video_player/video_player.dart';
/// import 'package:flutter/widgets.dart';
/// Widget progress(VideoPlayerController controller) => CollabMediaTimeline(
///   controller: controller,
///   mediaKind: 'audio',
///   onSeek: controller.seekTo,
/// );
/// // 调用方创建/初始化控制器，并在跳转完成后释放；进度条不释放控制器。
/// ```
class CollabMediaTimeline extends StatefulWidget {
  /// [key]控制状态复用；[controller]由外层拥有，本组件不释放。
  /// [onSeek]在松手时由资源拥有者执行跳转，Future完成前负责延迟播放器释放。
  /// [mediaKind]为audio或video，用于控件身份和错误文案；[overlay]默认false，
  /// 为true时使用适合深色视频画面的文字和轨道颜色。
  const CollabMediaTimeline({
    super.key,
    required this.controller,
    required this.onSeek,
    required this.mediaKind,
    this.overlay = false,
  });

  /// 当前播放器；ValueListenableBuilder持有并自动解绑借用监听。
  final VideoPlayerController controller;

  /// 由外层拥有者执行一次目标位置跳转，失败通过Future交给本视图提示。
  final Future<void> Function(Duration) onSeek;

  /// 媒体类别，必填audio或video；决定错误文案和测试/语义身份。
  final String mediaKind;

  /// 是否叠放在深色画面上；默认false使用适合音频卡片的文字与轨道颜色。
  final bool overlay;

  /// 创建仅持有拖动预览和跳转状态的局部State。
  @override
  createState() => _CollabMediaTimelineState();
}

/// 拖动只更新本地预览，松手后跳转一次；迟到结果不影响换源或退出后的组件。
class _CollabMediaTimelineState extends State<CollabMediaTimeline> {
  /// 拖动/跳转期间预览的毫秒位置；null时跟随实际播放位置。
  double? _previewMs;

  /// 当前跳转尚未完成时禁用重复拖动，不干预播放器的播放/暂停状态。
  bool _seeking = false;

  /// 控制器替换或新请求后失效旧跳转的本地序号。
  int _request = 0;

  /// [oldWidget]中的借用控制器更换后清空旧进度；旧Future仍由原控制器完成。
  @override
  void didUpdateWidget(covariant CollabMediaTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) {
      _request++;
      _previewMs = null;
      _seeking = false;
    }
  }

  /// 跳转到[value]毫秒（按当前时长限幅）；异步结束前校验控制器和请求身份。
  /// 失败保留当前位置并提示，不改正文；未知时长、失败或未初始化时忽略调用。
  Future<void> _seek(double value) async {
    final controller = widget.controller;
    final duration = controller.value.duration.inMilliseconds;
    if (!mounted || _seeking || !controller.value.isInitialized || controller.value.hasError || duration <= 0) {
      return;
    }
    final request = ++_request;
    final target = value.clamp(0.0, duration.toDouble());
    setState(() {
      _seeking = true;
      _previewMs = target;
    });
    try {
      await widget.onSeek(Duration(milliseconds: target.round()));
    } catch (error, stackTrace) {
      if (!mounted || !identical(controller, widget.controller) || request != _request) {
        return;
      }
      CollabDiagnostics.report(
        '${widget.mediaKind == 'audio' ? '音频' : '视频'}进度跳转失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('${widget.mediaKind == 'audio' ? '音频' : '视频'}跳转失败，请重试')));
    } finally {
      if (mounted && identical(controller, widget.controller) && request == _request) {
        setState(() {
          _seeking = false;
          _previewMs = null;
        });
      }
    }
  }

  /// 借用[context]构建局部进度监听；拖动期间不被播放计时覆盖，零时长不允许跳转。
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<VideoPlayerValue>(
    valueListenable: widget.controller,
    builder: (context, value, _) {
      final duration = value.duration.inMilliseconds;
      final max = duration > 0 ? duration.toDouble() : 1.0;
      final position = (_previewMs ?? value.position.inMilliseconds.toDouble()).clamp(0.0, duration > 0 ? max : 0.0);
      final enabled = value.isInitialized && !value.hasError && duration > 0 && !_seeking;
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeFocus(
              child: SizedBox(
                height: 32,
                child: SliderTheme(
                  data: SliderTheme.of(
                    context,
                  ).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5)),
                  child: Slider(
                    key: ValueKey('collab-${widget.mediaKind}-progress'),
                    value: position,
                    max: max,
                    activeColor: const Color(0xFF818CF8),
                    inactiveColor: widget.overlay ? Colors.white24 : const Color(0xFFE2E8F0),
                    semanticFormatterCallback: (v) => _mediaTime(Duration(milliseconds: v.round())),
                    onChangeStart: enabled ? (v) => setState(() => _previewMs = v) : null,
                    onChanged: enabled ? (v) => setState(() => _previewMs = v) : null,
                    onChangeEnd: enabled ? _seek : null,
                  ),
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    _mediaTime(Duration(milliseconds: position.round())),
                    key: ValueKey('collab-${widget.mediaKind}-position'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: widget.overlay ? Colors.white70 : const Color(0xFF64748B), fontSize: 11),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _mediaTime(value.duration),
                    key: ValueKey('collab-${widget.mediaKind}-duration'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: widget.overlay ? Colors.white70 : const Color(0xFF64748B), fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

/// 将非负[duration]格式化为mm:ss，超过一小时则显示h:mm:ss；负数按零显示。
String _mediaTime(Duration duration) {
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  final minutes = ((seconds ~/ 60) % 60).toString().padLeft(2, '0');
  final tail = (seconds % 60).toString().padLeft(2, '0');
  return seconds >= 3600 ? '${seconds ~/ 3600}:$minutes:$tail' : '$minutes:$tail';
}
