import 'dart:math' as math;
import 'document_cover_gallery.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';

import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

/// 在借用的 [context] 中展示媒体来源面板；[blockType] 为正文资源或document_banner/document_icon。
/// [initialValue] 默认空，预填链接；[allowRemove] 默认false，true允许返回空URL移除。
/// [canEdit] 是可选的提交时门禁，null不增加限制；[service] 借自宿主，null使用当前运行时端口。
/// Future等待面板完整退场后返回选中资源，取消为null；上传/校验失败留在面板中重试。
/// 不恢复正文焦点，调用方须用所属编辑器的操作会话隔离输入；Navigator错误透传。
Future<EditorMediaSource?> showEditorMediaSourceSheet(
  BuildContext context, {
  required String blockType,
  String initialValue = '',
  bool allowRemove = false,
  bool Function()? canEdit,
  EditorMediaUploadService? service,
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
      return EditorMediaSourcePanel(
        kind: blockType,
        initialValue: initialValue,
        allowRemove: allowRemove,
        canEdit: canEdit,
        service: service ?? CollabRuntime.services.mediaUpload,
      );
    },
  );
  // Navigator.pop completes before the reverse transition. Keep the editor
  // suspended until the sheet and its text input have actually been removed.
  await route?.completed;
  return result;
}

/// 共用来源面板：封面默认提供桌面图库，图标由调用方提供emoji页，其他资源提供链接/上传。
/// 本面板拥有输入、焦点、滚动与上传取消状态，借用上传服务；关闭后取消上传并忽略迟到结果。
/// 封面上方控件固定，下方内容滚动；上传期间禁止切换，提交时再次检查权限。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/editor/editor_media_source_sheet.dart';
/// import 'package:cses_document_collab/src/model/editor_media_upload.dart';
/// Future<EditorMediaSource?> chooseImage(BuildContext context) =>
///   showModalBottomSheet<EditorMediaSource>(context: context, isScrollControlled: true,
///     builder: (_) => const EditorMediaSourcePanel(kind: 'image', initialValue: ''));
/// // 正文编辑场景由调用方隔离输入并等待弹窗退场后恢复焦点。
/// ```
class EditorMediaSourcePanel extends StatefulWidget {
  /// [key] 标识状态，[kind] 指定资源类型，[initialValue] 为初始URL，可为空。
  /// [allowRemove] 默认false；[service] 借自宿主，null使用运行时端口，未配置时禁用上传。
  /// [firstTab] 与 [firstTabLabel] 必须同时提供或同时为null，否则触发断言；封面默认使用图库。
  /// [tabAction] 为可选顶部操作，提交中禁用；[onSelected] 为媒体确认回调，null由Navigator返回资源。
  /// [canEdit] 可选，确认前返回false时留面板提示只读；构造不选择文件或发网络请求。
  const EditorMediaSourcePanel({
    super.key,
    required this.kind,
    required this.initialValue,
    this.allowRemove = false,
    this.service,
    this.firstTab,
    this.firstTabLabel,
    this.tabAction,
    this.onSelected,
    this.canEdit,
  }) : assert((firstTab == null) == (firstTabLabel == null));

  /// 资源或业务头部类型，决定格式限制、默认Tab及视觉标签；必填，由调用方持有。
  final String kind;

  /// 初始链接，空值表示未设置；面板持有输入副本，切换来源保留内容。
  final String initialValue;

  /// 是否提供移除操作，默认false；空URL结果表示调用方应移除当前封面。
  final bool allowRemove;

  /// 借用的确认时权限回调；null表示不增加门禁，false阻止提交。
  final bool Function()? canEdit;

  /// 借用的上传端口；null使用运行时服务，面板不关闭服务或持有登录身份。
  final EditorMediaUploadService? service;

  /// 可选首Tab内容，如emoji列表；null时封面使用默认图库，其他类型无附加页。
  final Widget? firstTab;

  /// 附加首Tab标题，必须与 [firstTab] 同时设置；默认null。
  final String? firstTabLabel;

  /// 可选顶部操作，默认null；上传/选择文件期间屏蔽点击，封面可自动提供移除操作。
  final Widget? tabAction;

  /// 媒体确认时同步返回的借用回调；默认null，由Navigator弹出结果，回调负责后续保存。
  final ValueChanged<EditorMediaSource>? onSelected;

  /// 创建拥有输入、滚动和取消令牌的状态，借用业务上传端口。
  @override
  createState() => _MediaSourceSheetState();
}

/// 持有来源切换、输入、文件选择及上传状态；销毁时释放自有控制器并取消当前上传。
class _MediaSourceSheetState extends State<EditorMediaSourcePanel> {
  late final _url = TextEditingController(text: widget.initialValue);
  final _urlFocus = FocusNode();
  final _bannerScroll = ScrollController();

  /// 是否使用固定头部的封面面板；不改变数据或上传端口。
  bool get _banner => widget.kind == 'document_banner';

  /// 是否具有图库或借用的附加首Tab，用于默认来源与标签布局。
  bool get _hasFirstTab => _banner || widget.firstTab != null;
  late String _source = _hasFirstTab ? 'first' : 'link';

  /// 当前来源是否为本地文件；链接与首Tab不触发文件上传。
  bool get _local => _source == 'upload';
  late final _service = widget.service ?? CollabRuntime.services.mediaUpload;

  /// 将获准的媒体 [source] 同步交给回调或Navigator；不执行业务保存，回调异常由调用边界处理。
  void _complete(EditorMediaSource source) {
    if (widget.onSelected != null) {
      widget.onSelected!(source);
    } else {
      Navigator.pop(context, source);
    }
  }

  bool _picking = false;
  bool _uploading = false;
  EditorLocalFile? _file;
  String? _error;
  double _progress = 0;
  CancelToken? _cancel;

  /// 文件选择或上传中的互斥状态，期间禁止重复提交和切换来源。
  bool get _busy => _picking || _uploading;

  /// 资源类型对应的用户标签；未知类型使用链接标签。
  String get _label => switch (widget.kind) {
    'image' => '图片',
    'document_banner' => '封面图片',
    'document_icon' => '图标图片',
    'video' => '视频',
    'audio' => '音频',
    'attachment' => '附件',
    'bookmark' => '网页卡片',
    'embed' => '网页嵌入',
    'figma-embed' => 'Figma',
    'juejin-embed' => '掘金',
    _ => '链接',
  };

  /// 当前资源的装饰图标，无业务含义。
  IconData get _icon => switch (widget.kind) {
    'image' || 'document_banner' || 'document_icon' => Icons.image_outlined,
    'video' => Icons.videocam_outlined,
    'audio' => Icons.audiotrack_outlined,
    'attachment' => Icons.attach_file,
    _ => Icons.link,
  };

  /// 链接输入的格式示例，不作为实际资源或默认保存值。
  String get _hint => switch (widget.kind) {
    'image' ||
    'document_banner' ||
    'document_icon' => 'https://example.com/image.png',
    'video' => 'https://example.com/video.mp4',
    'audio' => 'https://example.com/audio.mp3',
    _ => 'https://example.com/resource',
  };

  /// 当前类型允许的上传格式和大小说明，与文件验证边界一致。
  String get _fileHint => switch (widget.kind) {
    'image' || 'document_banner' => '支持 PNG、JPG、GIF、WebP，最大 60 MB',
    'document_icon' => '支持 PNG、JPG、GIF、WebP、SVG，最大 60 MB',
    'video' => '选择视频文件，最大 100 MB',
    'audio' => '选择音频文件，最大 50 MB',
    _ => '选择本地文件，最大 100 MB',
  };

  /// 读取借用的权限门禁，失效时显示只读提示并返回false；不发请求或关闭面板。
  bool _checkEditable() {
    if (widget.canEdit?.call() == false) {
      setState(() => _error = '文档已进入只读，请关闭面板后重新查看');
      return false;
    }
    return true;
  }

  /// 经借用服务选择单个文件，验证格式/大小并保留可重选的文件状态。
  /// 取消或销毁后忽略结果；异常转换为面板错误，Future在选择和互斥状态更新后完成。
  Future<void> _pick() async {
    if (_busy || !_checkEditable()) return;
    _urlFocus.unfocus();
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final file = await _service!.pickFile(widget.kind);
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

  /// 确认当前链接或上传已选文件；先检查权限和互斥，成功交出稳定URL。
  /// 非法链接/上传失败留面板展示错误，可重试；取消、销毁或权限失效后忽略迟到成功。
  /// Future在上传及状态更新后完成；服务借用，取消令牌由本状态持有。
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
      _complete(EditorMediaSource(url));
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
      final result = await _service!.upload(
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
        _complete(result);
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

  /// 取消所属上传并释放输入、焦点和封面滚动控制器；借用的宿主服务不释放。
  @override
  void dispose() {
    _cancel?.cancel('source sheet closed');
    _url.dispose();
    _urlFocus.dispose();
    _bannerScroll.dispose();
    super.dispose();
  }

  /// 在 [context] 中按屏幕/键盘约束构建来源页；封面固定上方控件，仅下方内容滚动。
  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF5B5BD6);
    final upload = _service != null && editorMediaSupportsUpload(widget.kind);
    final tabAction =
        widget.tabAction ??
        (_banner && widget.allowRemove
            ? TextButton.icon(
                key: const ValueKey('editor-cover-url-remove'),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () {
                  if (!_busy && _checkEditable()) {
                    _complete(const EditorMediaSource(''));
                  }
                },
                icon: const Icon(Icons.remove_circle_outline, size: 16),
                label: const Text('移除封面'),
              )
            : null);
    final headerChildren = <Widget>[
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
                  widget.kind == 'document_icon' && widget.firstTab != null
                      ? '修改图标'
                      : _label,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF202636),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _banner
                      ? '选择图库图片、上传图片或使用链接'
                      : widget.firstTab != null
                      ? '选择表情或图片作为文档图标'
                      : upload
                      ? '通过链接或本地文件添加$_label'
                      : '通过链接添加$_label',
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
      if (upload || _hasFirstTab) ...[
        Row(
          children: [
            if (_hasFirstTab)
              _tab(
                'first',
                _banner ? '公共图库' : widget.firstTabLabel!,
                _banner
                    ? Icons.photo_library_outlined
                    : Icons.emoji_emotions_outlined,
              ),
            if (_hasFirstTab) ...[
              _tab('upload', '上传', Icons.file_upload_outlined),
              _tab('link', '链接', Icons.link),
            ] else ...[
              _tab('link', '链接', Icons.link),
              _tab('upload', '本地上传', Icons.file_upload_outlined),
            ],
          ],
        ),
        const Divider(height: 1, color: Color(0xFFE9EBF1)),
        const SizedBox(height: 20),
      ],
      if (tabAction != null) ...[
        Align(
          alignment: Alignment.centerRight,
          child: _busy
              ? IgnorePointer(child: Opacity(opacity: .4, child: tabAction))
              : tabAction,
        ),
        const SizedBox(height: 8),
      ],
    ];
    final contentChildren = <Widget>[
      if (_source == 'first')
        widget.firstTab ??
            DocumentCoverGallery(
              selectedUrl: widget.initialValue,
              onSelected: (image) {
                if (!_busy && _checkEditable()) {
                  _complete(EditorMediaSource(image.url));
                }
              },
            )
      else if (!_local) ...[
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
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 10),
        Text(
          '支持可直接访问的$_label链接',
          style: const TextStyle(fontSize: 12, color: Color(0xFF7C8799)),
        ),
      ] else ...[
        Material(
          color: const Color(0xFFF8F9FC),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            key: const ValueKey('editor-media-pick-file'),
            onTap: _busy || !upload ? null : _pick,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFE0E4EE)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Icon(
                    _file == null ? Icons.cloud_upload_outlined : _icon,
                    size: 32,
                    color: accent,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _picking ? '正在选择文件…' : (_file?.name ?? '点击选择$_label文件'),
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
                        ? (upload
                              ? _fileHint
                              : _banner
                              ? '当前环境暂不支持图片上传，请使用图库或链接'
                              : '当前环境暂不支持图片上传，请使用表情或链接')
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
            _progress >= 1 ? '正在保存文件…' : '正在上传 ${(_progress * 100).round()}%',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFF7C8799)),
          ),
        ],
      ],
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            _error!,
            key: const ValueKey('editor-media-source-error'),
            style: const TextStyle(fontSize: 12, color: Color(0xFFC33C45)),
          ),
        ),
      if (_source != 'first') ...[
        const SizedBox(height: 24),
        OverflowBar(
          alignment: MainAxisAlignment.end,
          overflowAlignment: OverflowBarAlignment.end,
          spacing: 10,
          children: [
            if (widget.allowRemove && !_banner)
              TextButton(
                key: const ValueKey('editor-cover-url-remove'),
                onPressed: _busy
                    ? null
                    : () => Navigator.pop(context, const EditorMediaSource('')),
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
                  _busy || (_local ? _file == null : _url.text.trim().isEmpty)
                  ? null
                  : _submit,
              child: Text(
                _uploading
                    ? '上传中…'
                    : _local
                    ? widget.kind == 'document_icon' || _banner
                          ? '上传并保存'
                          : '上传并插入'
                    : '确定',
              ),
            ),
          ],
        ),
      ],
    ];
    final content = SingleChildScrollView(
      key: ValueKey('editor-${widget.kind}-source-sheet'),
      controller: _banner ? _bannerScroll : null,
      padding: EdgeInsets.fromLTRB(20, _banner ? 0 : 12, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [if (!_banner) ...headerChildren, ...contentChildren],
      ),
    );
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
          child: _banner
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      key: const ValueKey('document-cover-source-header'),
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: headerChildren,
                      ),
                    ),
                    Expanded(child: content),
                  ],
                )
              : content,
        ),
      ),
    );
  }

  /// 将内部来源 [source] 展示为 [label] 和装饰 [icon]；点击失焦输入并清错误。
  /// 封面内容回到顶部，链接和文件状态保留；上传/选择期间禁止切换，无网络副作用。
  Widget _tab(String source, String label, IconData icon) => Expanded(
    child: Semantics(
      button: true,
      selected: _source == source,
      enabled: !_busy,
      child: InkWell(
        key: ValueKey(switch (source) {
          'first' =>
            _banner ? 'document-cover-library-tab' : 'document-icon-emoji-tab',
          'upload' => 'editor-media-upload-tab',
          _ => 'editor-media-link-tab',
        }),
        onTap: _busy
            ? null
            : () {
                FocusScope.of(context).unfocus();
                if (_banner && _bannerScroll.hasClients) {
                  _bannerScroll.jumpTo(0);
                }
                setState(() {
                  _source = source;
                  _error = null;
                });
              },
        child: Container(
          padding: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: _source == source
                    ? const Color(0xFF5B5BD6)
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!_hasFirstTab)
                Icon(
                  icon,
                  size: 17,
                  color: _source == source
                      ? const Color(0xFF5B5BD6)
                      : const Color(0xFF7C8799),
                ),
              if (!_hasFirstTab) const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: _source == source
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: _source == source
                        ? const Color(0xFF5B5BD6)
                        : const Color(0xFF7C8799),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
