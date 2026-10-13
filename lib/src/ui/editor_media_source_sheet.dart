import 'dart:math' as math;

import 'package:cses_mobile_collab_demo/src/collab/collab_resource.dart';
import 'package:cses_mobile_collab_demo/src/collab/editor_media_upload.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

/// Mobile source chooser shared by the add menu, compact toolbar and cover.
Future<EditorMediaSource?> showEditorMediaSourceSheet(
  BuildContext context, {
  required String blockType,
  String initialValue = '',
  bool allowRemove = false,
  bool Function()? canEdit,
  EditorMediaUploadService service = const CsesEditorMediaUploadService(),
}) async {
  ModalRoute<EditorMediaSource>? route;
  final result = await showModalBottomSheet<EditorMediaSource>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    clipBehavior: Clip.antiAlias,
    requestFocus: true,
    builder: (context) {
      route = ModalRoute.of<EditorMediaSource>(context);
      return _MediaSourceSheet(
        kind: blockType,
        initialValue: initialValue,
        allowRemove: allowRemove,
        canEdit: canEdit,
        service: service,
      );
    },
  );
  // Navigator.pop completes before the reverse transition. Keep the editor
  // suspended until the sheet and its text input have actually been removed.
  await route?.completed;
  return result;
}

class _MediaSourceSheet extends StatefulWidget {
  const _MediaSourceSheet({
    required this.kind,
    required this.initialValue,
    required this.allowRemove,
    required this.service,
    this.canEdit,
  });
  final String kind;
  final String initialValue;
  final bool allowRemove;
  final bool Function()? canEdit;
  final EditorMediaUploadService service;
  @override
  State<_MediaSourceSheet> createState() => _MediaSourceSheetState();
}

class _MediaSourceSheetState extends State<_MediaSourceSheet> {
  late final _url = TextEditingController(text: widget.initialValue);
  final _urlFocus = FocusNode();
  bool _local = false;
  bool _picking = false;
  bool _uploading = false;
  EditorLocalFile? _file;
  String? _error;
  double _progress = 0;
  CancelToken? _cancel;
  bool get _busy => _picking || _uploading;
  String get _label => switch (widget.kind) {
    'image' => '图片',
    'document_cover' => '封面图片',
    'video' => '视频',
    'audio' => '音频',
    'attachment' => '附件',
    'bookmark' => '网页卡片',
    'embed' => '网页嵌入',
    'figma-embed' => 'Figma',
    'juejin-embed' => '掘金',
    _ => '链接',
  };
  IconData get _icon => switch (widget.kind) {
    'image' || 'document_cover' => Icons.image_outlined,
    'video' => Icons.videocam_outlined,
    'audio' => Icons.audiotrack_outlined,
    'attachment' => Icons.attach_file,
    _ => Icons.link,
  };
  String get _hint => switch (widget.kind) {
    'image' || 'document_cover' => 'https://example.com/image.png',
    'video' => 'https://example.com/video.mp4',
    'audio' => 'https://example.com/audio.mp3',
    _ => 'https://example.com/resource',
  };
  String get _fileHint => switch (widget.kind) {
    'image' || 'document_cover' => '支持 PNG、JPG、GIF、WebP，最大 60 MB',
    'video' => '选择视频文件，最大 100 MB',
    'audio' => '选择音频文件，最大 50 MB',
    _ => '选择本地文件，最大 100 MB',
  };

  bool _checkEditable() {
    if (widget.canEdit?.call() == false) {
      setState(() => _error = '文档已进入只读，请关闭面板后重新查看');
      return false;
    }
    return true;
  }

  Future<void> _pick() async {
    if (_busy || !_checkEditable()) return;
    _urlFocus.unfocus();
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final file = await widget.service.pickFile(widget.kind);
      if (!mounted || file == null) return;
      final error = validateEditorMediaFile(widget.kind, file);
      setState(() {
        if (error == null) _file = file;
        _error = error;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException ? e.message : '无法选择文件，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _submit() async {
    if (_busy || !_checkEditable()) return;
    if (!_local) {
      final url = _url.text.trim();
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !{'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          (isCollabResourceType(widget.kind) &&
              !isCollabResourceUrl(widget.kind, url))) {
        setState(() => _error = '请输入完整的 http:// 或 https:// 链接');
        return;
      }
      Navigator.pop(context, EditorMediaSource(url));
      return;
    }
    final file = _file;
    if (file == null) return;
    final cancel = CancelToken();
    _cancel = cancel;
    setState(() {
      _uploading = true;
      _progress = 0;
      _error = null;
    });
    try {
      final result = await widget.service.upload(
        file,
        widget.kind,
        cancelToken: cancel,
        onProgress: (value) {
          if (mounted && !cancel.isCancelled) {
            setState(() => _progress = value.clamp(0, 1));
          }
        },
      );
      if (mounted && !cancel.isCancelled && _checkEditable()) {
        Navigator.pop(context, result);
      }
    } catch (e) {
      if (mounted && !cancel.isCancelled) {
        setState(
          () => _error = e is FormatException ? e.message : '上传失败，请检查网络后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  void dispose() {
    _cancel?.cancel('source sheet closed');
    _url.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF5B5BD6);
    final upload = editorMediaSupportsUpload(widget.kind);
    return AnimatedPadding(
      duration: const Duration(milliseconds: 160),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: math.max(
              0,
              MediaQuery.sizeOf(context).height * .9 -
                  MediaQuery.viewInsetsOf(context).bottom,
            ),
          ),
          child: SingleChildScrollView(
            key: ValueKey('editor-${widget.kind}-source-sheet'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE1E3E9),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: const Color(0xFFEEEEFF),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(_icon, color: accent, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _label,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF202636),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            upload ? '通过链接或本地文件添加$_label' : '通过链接添加$_label',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF7C8799),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('editor-media-source-close'),
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (upload) ...[
                  Row(
                    children: [
                      _tab(false, '链接', Icons.link),
                      _tab(true, '本地上传', Icons.file_upload_outlined),
                    ],
                  ),
                  const Divider(height: 1, color: Color(0xFFE9EBF1)),
                  const SizedBox(height: 20),
                ],
                if (!_local) ...[
                  TextField(
                    key: const ValueKey('editor-url-block-input'),
                    controller: _url,
                    focusNode: _urlFocus,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      hintText: _hint,
                      labelText: '$_label链接',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 16,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '支持可直接访问的$_label链接',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF7C8799),
                    ),
                  ),
                ] else ...[
                  Material(
                    color: const Color(0xFFF8F9FC),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      key: const ValueKey('editor-media-pick-file'),
                      onTap: _busy ? null : _pick,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 24,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: const Color(0xFFE0E4EE)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            Icon(
                              _file == null
                                  ? Icons.cloud_upload_outlined
                                  : _icon,
                              size: 32,
                              color: accent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _picking
                                  ? '正在选择文件…'
                                  : (_file?.name ?? '点击选择$_label文件'),
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _file == null
                                  ? _fileHint
                                  : '${(_file!.size / 1024 / 1024).toStringAsFixed(2)} MB · 点击重新选择',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF7C8799),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_uploading) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: _progress,
                      color: accent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _progress >= 1
                          ? '正在保存文件…'
                          : '正在上传 ${(_progress * 100).round()}%',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF7C8799),
                      ),
                    ),
                  ],
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      key: const ValueKey('editor-media-source-error'),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFC33C45),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  overflowAlignment: OverflowBarAlignment.end,
                  spacing: 10,
                  children: [
                    if (widget.allowRemove)
                      TextButton(
                        key: const ValueKey('editor-cover-url-remove'),
                        onPressed: _busy
                            ? null
                            : () => Navigator.pop(
                                context,
                                const EditorMediaSource(''),
                              ),
                        child: const Text('移除封面'),
                      ),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      key: const ValueKey('editor-url-block-submit'),
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 13,
                        ),
                      ),
                      onPressed:
                          _busy ||
                              (_local
                                  ? _file == null
                                  : _url.text.trim().isEmpty)
                          ? null
                          : _submit,
                      child: Text(
                        _uploading
                            ? '上传中…'
                            : _local
                            ? '上传并插入'
                            : '确定',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(bool local, String label, IconData icon) => Expanded(
    child: InkWell(
      key: ValueKey(
        local ? 'editor-media-upload-tab' : 'editor-media-link-tab',
      ),
      onTap: _busy
          ? null
          : () {
              _urlFocus.unfocus();
              setState(() {
                _local = local;
                _error = null;
              });
            },
      child: Container(
        padding: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: _local == local
                  ? const Color(0xFF5B5BD6)
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 17,
              color: _local == local
                  ? const Color(0xFF5B5BD6)
                  : const Color(0xFF7C8799),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: _local == local
                    ? FontWeight.w600
                    : FontWeight.normal,
                color: _local == local
                    ? const Color(0xFF5B5BD6)
                    : const Color(0xFF7C8799),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
