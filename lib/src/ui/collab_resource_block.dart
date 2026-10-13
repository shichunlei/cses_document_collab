import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_resource.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_unsupported_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

String collabResourceLabel(String kind) => switch (kind) {
  'attachment' => '附件',
  'audio' => '音频',
  'bookmark' => '网页卡片',
  'figma-embed' => 'Figma',
  'juejin-embed' => '掘金',
  _ => '网页嵌入',
};
IconData _icon(String kind) => switch (kind) {
  'attachment' => Icons.insert_drive_file_outlined,
  'audio' => Icons.audiotrack_outlined,
  'bookmark' => Icons.bookmark_border,
  'figma-embed' => Icons.design_services_outlined,
  'juejin-embed' => Icons.article_outlined,
  _ => Icons.language,
};

Uri collabResourceFrameUrl(String kind, String url) => kind == 'figma-embed'
    ? Uri.https('www.figma.com', '/embed', {'embed_host': 'share', 'url': url})
    : Uri.parse(url);

Future<void> _open(BuildContext context, String url) async {
  try {
    final uri = Uri.tryParse(url);
    if (uri != null &&
        isCollabResourceUrl('embed', url) &&
        await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (_) {
    /* Surface failure in the card's host, not an uncaught callback. */
  }
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('无法打开此资源，请检查链接')));
  }
}

/// Selectable, non-text resource surface. Owns no collaboration or network session.
class CollabResourceBlockComponentBuilder extends BlockComponentBuilder {
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && node.children.isEmpty;
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    final url = context.node.attributes[csesEmbedUrlAttribute] as String? ?? '';
    if (!isCollabResourceUrl(context.node.type, url)) {
      return CollabUnsupportedBlockComponentBuilder().build(context);
    }
    return _ResourceBlock(
      key: context.node.key,
      node: context.node,
      configuration: configuration,
    );
  }
}

class _ResourceBlock extends BlockComponentStatefulWidget {
  const _ResourceBlock({
    super.key,
    required super.node,
    required super.configuration,
  });
  @override
  State<_ResourceBlock> createState() => _ResourceBlockState();
}

class _ResourceBlockState extends State<_ResourceBlock> with SelectableMixin {
  final _bodyKey = GlobalKey();
  late final _editor = context.read<EditorState>();
  String get _url =>
      widget.node.attributes[csesEmbedUrlAttribute] as String? ?? '';
  String get _id =>
      widget.node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute]
          as String? ??
      widget.node.id;

  Future<void> _delete() async {
    if (!_editor.editable || _editor.isDisposed || widget.node.parent == null) {
      return;
    }
    final node = widget.node;
    final transaction = _editor.transaction..deleteNode(node);
    if (_editor.document.root.children.length == 1 &&
        node.parent == _editor.document.root) {
      transaction.insertNode([0], paragraphNode());
      transaction.afterSelection = Selection.single(path: [0], startOffset: 0);
    } else {
      transaction.afterSelection = null;
    }
    await _editor.apply(transaction);
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final kind = node.type;
    final props = CollabResource.fromAttributes(node.attributes);
    final label = collabResourceLabel(kind);
    final title = props.string(kind == 'bookmark' ? 'title' : 'name');
    final name = title.isNotEmpty
        ? title
        : (kind == 'attachment'
              ? Uri.parse(_url).pathSegments.lastOrNull ?? label
              : label);
    final isFrame = {'embed', 'figma-embed', 'juejin-embed'}.contains(kind);
    final child = Container(
      key: _bodyKey,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Icon(_icon(kind), size: 22, color: const Color(0xFF64748B)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _subtitle(kind, props, _url),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF87909E),
                        ),
                      ),
                    ],
                  ),
                ),
                ExcludeFocus(
                  child: IconButton(
                    key: ValueKey('resource-open-$_id'),
                    tooltip: kind == 'attachment' ? '下载或打开附件' : '在浏览器打开',
                    icon: const Icon(Icons.open_in_new, size: 18),
                    onPressed: () => _open(context, _url),
                  ),
                ),
                if (_editor.editable) ...[
                  ExcludeFocus(
                    child: IconButton(
                      key: ValueKey('resource-edit-$_id'),
                      tooltip: '修改$label',
                      icon: const Icon(Icons.tune, size: 18),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => _ResourceSettings(
                          editor: _editor,
                          id: _id,
                          kind: kind,
                          url: _url,
                          props: props,
                        ),
                      ),
                    ),
                  ),
                  ExcludeFocus(
                    child: IconButton(
                      key: ValueKey('resource-delete-$_id'),
                      tooltip: '删除$label',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _delete,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (kind == 'bookmark') _BookmarkPreview(props: props, url: _url),
          if (kind == 'audio')
            _AudioPlayer(key: ValueKey('audio:$_url'), url: _url),
          if (isFrame)
            LayoutBuilder(
              builder: (context, constraints) {
                final ratio = props.number('ar');
                final wr = props.number('wr');
                final ratioMode =
                    (wr != null && wr > 0) || (ratio != null && ratio > 0);
                final width = ratioMode
                    ? constraints.maxWidth * ((wr ?? 100).clamp(1, 100) / 100)
                    : (props.number('width') ?? constraints.maxWidth).clamp(
                        1.0,
                        constraints.maxWidth,
                      );
                final height =
                    (ratioMode
                            ? width /
                                  ((ratio != null && ratio > 0)
                                      ? ratio
                                      : 16 / 9)
                            : props.number('height') ?? width / (16 / 9))
                        .clamp(180.0, 720.0);
                return Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: _EmbeddedPage(
                      key: ValueKey('$kind:$_url'),
                      url: collabResourceFrameUrl(kind, _url),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
    return BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: _editor.selectionNotifier,
      remoteSelection: _editor.remoteSelections,
      blockColor: _editor.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      selectionAboveBlock: true,
      child: child,
    );
  }

  @override
  Position start() => Position(path: widget.node.path);
  @override
  Position end() => Position(path: widget.node.path, offset: 1);
  @override
  Position getPositionInOffset(Offset offset) => end();
  @override
  bool get shouldCursorBlink => false;
  @override
  CursorStyle get cursorStyle => CursorStyle.cover;
  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) {
    final outer = context.findRenderObject();
    final inner = _bodyKey.currentContext?.findRenderObject();
    if (outer is! RenderBox || inner is! RenderBox) return Rect.zero;
    return inner.localToGlobal(Offset.zero, ancestor: outer) & inner.size;
  }

  @override
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) => getBlockRect();
  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) => [getBlockRect()];
  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);
  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      (context.findRenderObject() as RenderBox).localToGlobal(offset);
}

String _subtitle(String kind, CollabResource props, String url) {
  final host = Uri.parse(url).host;
  if (kind != 'attachment') return host;
  final size = props.number('size');
  final type = props.string('type');
  return [
    if (type.isNotEmpty) type.split('/').last.toUpperCase(),
    if (size != null && size > 0)
      size >= 1048576
          ? '${(size / 1048576).toStringAsFixed(1)} MB'
          : '${(size / 1024).toStringAsFixed(1)} KB',
    host,
  ].join(' · ');
}

class _BookmarkPreview extends StatelessWidget {
  const _BookmarkPreview({required this.props, required this.url});
  final CollabResource props;
  final String url;
  @override
  Widget build(BuildContext context) {
    final image = props.string('image');
    final description = props.string('description');
    if (image.isEmpty && description.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: () => _open(context, url),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (description.isNotEmpty)
              Expanded(
                child: Text(
                  description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF64748B),
                  ),
                ),
              ),
            if (isCollabResourceUrl('bookmark', image))
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(
                    image,
                    width: 80,
                    height: 64,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Owns one audio controller. Keyed by URL so replacement disposes the old stream.
class _AudioPlayer extends StatefulWidget {
  const _AudioPlayer({super.key, required this.url});
  final String url;
  @override
  State<_AudioPlayer> createState() => _AudioPlayerState();
}

class _AudioPlayerState extends State<_AudioPlayer> {
  late final VideoPlayerController _controller;
  String? _error;
  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller.addListener(_refresh);
    unawaited(_load());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await _controller.initialize();
    } catch (_) {
      if (mounted) setState(() => _error = '音频加载失败');
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '音频操作失败');
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_refresh);
    unawaited(_controller.dispose().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _controller.value;
    if (_error != null || value.hasError) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          _error ?? '音频加载失败，可在浏览器打开',
          style: const TextStyle(color: Color(0xFF87909E), fontSize: 12),
        ),
      );
    }
    if (!value.isInitialized) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    final duration = value.duration.inMilliseconds.toDouble();
    return Row(
      children: [
        ExcludeFocus(
          child: IconButton(
            tooltip: value.isPlaying ? '暂停音频' : '播放音频',
            icon: Icon(
              value.isPlaying
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_fill,
              color: const Color(0xFF5B5BD6),
            ),
            onPressed: () =>
                _act(value.isPlaying ? _controller.pause : _controller.play),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.position.inMilliseconds.toDouble().clamp(
              0,
              duration > 0 ? duration : 1,
            ),
            max: duration > 0 ? duration : 1,
            onChanged: duration > 0
                ? (v) => _act(
                    () => _controller.seekTo(Duration(milliseconds: v.round())),
                  )
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text(
            '${_time(value.position)} / ${_time(value.duration)}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
          ),
        ),
      ],
    );
  }
}

String _time(Duration value) =>
    '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';

/// Platform-owned webview; navigation is limited to web URLs, with no native JS bridge.
class _EmbeddedPage extends StatefulWidget {
  const _EmbeddedPage({super.key, required this.url});
  final Uri url;
  @override
  State<_EmbeddedPage> createState() => _EmbeddedPageState();
}

class _EmbeddedPageState extends State<_EmbeddedPage> {
  WebViewController? _controller;
  String? _error;
  int _progress = 0;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    if (WebViewPlatform.instance != null) unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    bool current() => mounted && generation == _generation;
    try {
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onProgress: (v) {
            if (current()) setState(() => _progress = v);
          },
          onWebResourceError: (e) {
            if (current() && e.isForMainFrame != false) {
              setState(() => _error = '网页暂时无法加载');
            }
          },
          onNavigationRequest: (r) => isCollabResourceUrl('embed', r.url)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );
      if (!current()) return;
      await controller.loadRequest(widget.url);
      if (current()) setState(() {});
    } catch (_) {
      if (current()) setState(() => _error = '网页暂时无法加载');
    }
  }

  @override
  void dispose() {
    _generation++;
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_error != null || controller == null) {
      return ColoredBox(
        color: const Color(0xFFF8FAFC),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.language, color: Color(0xFF94A3B8), size: 32),
              const SizedBox(height: 8),
              Text(
                _error ?? '当前设备不支持内嵌浏览',
                style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
              TextButton(
                onPressed: () => _open(context, widget.url.toString()),
                child: const Text('在浏览器打开'),
              ),
              if (_error != null)
                TextButton(
                  onPressed: () {
                    setState(() {
                      _error = null;
                      _progress = 0;
                    });
                    unawaited(_load());
                  },
                  child: const Text('重试'),
                ),
            ],
          ),
        ),
      );
    }
    return Stack(
      children: [
        WebViewWidget(
          key: ValueKey(controller),
          controller: controller,
          gestureRecognizers: {
            Factory<EagerGestureRecognizer>(() => EagerGestureRecognizer()),
          },
        ),
        if (_progress < 100)
          LinearProgressIndicator(value: _progress / 100, minHeight: 2),
      ],
    );
  }
}

class _ResourceSettings extends StatefulWidget {
  const _ResourceSettings({
    required this.editor,
    required this.id,
    required this.kind,
    required this.url,
    required this.props,
  });
  final EditorState editor;
  final String id;
  final String kind;
  final String url;
  final CollabResource props;
  @override
  State<_ResourceSettings> createState() => _ResourceSettingsState();
}

class _ResourceSettingsState extends State<_ResourceSettings> {
  late final Map<String, TextEditingController> _fields;
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _fields = {
      'url': TextEditingController(text: widget.url),
      if ({'attachment', 'audio'}.contains(widget.kind))
        'name': TextEditingController(text: widget.props.string('name')),
      if (widget.kind == 'bookmark') ...{
        'title': TextEditingController(text: widget.props.string('title')),
        'description': TextEditingController(
          text: widget.props.string('description'),
        ),
      },
      if ({'embed', 'figma-embed', 'juejin-embed'}.contains(widget.kind)) ...{
        'wr': TextEditingController(
          text: (widget.props.number('wr') ?? 100).toString(),
        ),
        'ar': TextEditingController(
          text: (widget.props.number('ar') ?? 16 / 9).toStringAsFixed(3),
        ),
      },
    };
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final url = _fields['url']!.text.trim();
    if (!isCollabResourceUrl(widget.kind, url)) {
      setState(
        () => _error = widget.kind == 'figma-embed'
            ? '请输入 Figma 链接'
            : widget.kind == 'juejin-embed'
            ? '请输入掘金链接'
            : '请输入完整的 HTTP(S) 地址',
      );
      return;
    }
    final changes = <String, Object?>{};
    for (final entry in _fields.entries) {
      final text = entry.value.text.trim();
      if (entry.key == 'url') {
        if (text != widget.url) changes['url'] = text;
        continue;
      }
      if ({'wr', 'ar'}.contains(entry.key)) {
        final initial = entry.key == 'wr'
            ? (widget.props.number('wr') ?? 100).toString()
            : (widget.props.number('ar') ?? 16 / 9).toStringAsFixed(3);
        if (text == initial) continue;
        final number = double.tryParse(text);
        if (number == null ||
            !number.isFinite ||
            number <= 0 ||
            (entry.key == 'wr' && number > 100)) {
          setState(() => _error = '宽度应为 1–100，宽高比应为正数');
          return;
        }
        changes[entry.key] = number;
      } else if (text != widget.props.string(entry.key)) {
        changes[entry.key] = text.isEmpty ? null : text;
      }
    }
    if (widget.editor.isDisposed || !widget.editor.editable) return;
    Node? find(Node n) {
      if ((n.attributes['cses_collab_block_id'] ?? n.id) == widget.id &&
          n.type == widget.kind) {
        return n;
      }
      for (final c in n.children) {
        final v = find(c);
        if (v != null) return v;
      }
      return null;
    }

    final node = find(widget.editor.document.root);
    if (node == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final latest = CollabResource.fromAttributes(node.attributes);
    if (changes.keys.any(
      (key) => key == 'url'
          ? node.attributes['url'] != widget.url
          : latest.field(key) != widget.props.field(key),
    )) {
      setState(() => _error = '内容已被更新，请重新打开设置');
      return;
    }
    setState(() => _saving = true);
    try {
      for (final entry in changes.entries) {
        await changeCollabResourceProperty(
          widget.editor,
          widget.id,
          entry.key,
          entry.value,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '保存失败，请重试';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('修改${collabResourceLabel(widget.kind)}'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in _fields.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                key: ValueKey('resource-field-${entry.key}'),
                controller: entry.value,
                maxLines: entry.key == 'description' ? 3 : 1,
                decoration: InputDecoration(
                  labelText: switch (entry.key) {
                    'url' => '资源链接',
                    'name' => '名称',
                    'title' => '标题',
                    'description' => '摘要',
                    'wr' => '宽度（%）',
                    _ => '宽高比',
                  },
                ),
              ),
            ),
          if (_error != null)
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
    ],
  );
}
