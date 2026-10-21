import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_field.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_segments.dart';
import 'package:cses_document_collab/src/ui/modal/document_cover_gallery.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 共用来源面板：封面默认提供桌面图库，图标由调用方提供emoji页，其他资源提供链接/上传。
/// 本面板拥有输入、焦点、滚动与上传取消状态，借用上传服务；关闭后取消上传并忽略迟到结果。
/// 封面上方控件固定，下方内容滚动；上传期间禁止切换，提交时再次检查权限。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// import 'package:cses_document_collab/src/ui/modal/editor_media_source_panel.dart';
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/model/editor_media_upload.dart';
/// Future<EditorMediaSource?> chooseImage(BuildContext context) =>
///   showCollabBottomSheet<EditorMediaSource>(context: context,
///     builder: (_) => const EditorMediaSourcePanel(kind: 'image', initialValue: ''));
/// // 正文编辑场景由调用方隔离输入并等待弹窗退场后恢复焦点。
/// ```
class EditorMediaSourcePanel extends StatefulWidget {
  /// [key] 标识状态，[kind] 指定资源类型，[initialValue] 为初始URL，可为空。
  /// [allowRemove] 默认false；[service] 借自宿主，null使用运行时端口，未配置时禁用上传。
  /// [useRuntimeService]默认true；实例调用传false，null服务就保持禁用上传。
  /// [firstTab] 与 [firstTabLabel] 必须同时提供或同时为null，否则触发断言；封面默认使用图库。
  /// [firstTabOwnsScroll] 默认false；true要求[firstTab]非空，首Tab自行滚动，不影响链接/上传Tab。
  /// [leadingAction] 为可选底部左侧操作，选择/上传期间屏蔽点击；[onSelected] 为媒体确认回调，null由Navigator返回资源。
  /// [canEdit] 可选，确认前返回false时留面板提示只读；构造不选择文件或发网络请求。
  const EditorMediaSourcePanel({
    super.key,
    required this.kind,
    required this.initialValue,
    this.allowRemove = false,
    this.service,
    this.useRuntimeService = true,
    this.firstTab,
    this.firstTabLabel,
    this.firstTabOwnsScroll = false,
    this.leadingAction,
    this.onSelected,
    this.canEdit,
  }) : assert((firstTab == null) == (firstTabLabel == null)),
       assert(!firstTabOwnsScroll || firstTab != null);

  /// 资源或业务头部类型，决定格式限制、默认Tab及视觉标签；必填，由调用方持有。
  final String kind;

  /// 初始链接，空值表示未设置；面板持有输入副本，切换来源保留内容。
  final String initialValue;

  /// 是否提供移除操作，默认false；空URL结果表示调用方应移除当前封面。
  final bool allowRemove;

  /// 借用的确认时权限回调；null表示不增加门禁，false阻止提交。
  final bool Function()? canEdit;

  /// 是否允许null上传端口回退到全局服务；默认true保留历史独立调用。
  final bool useRuntimeService;

  /// 借用的上传端口；null仅在useRuntimeService开启时回退运行时，面板不关闭服务。
  final EditorMediaUploadService? service;

  /// 可选首Tab内容，如emoji列表；null时封面使用默认图库，其他类型无附加页。
  final Widget? firstTab;

  /// 首Tab是否自行滚动，默认false；仅用于自带惰性目录的内容，不改变其他来源的外壳滚动。
  final bool firstTabOwnsScroll;

  /// 附加首Tab标题，必须与 [firstTab] 同时设置；默认null。
  final String? firstTabLabel;

  /// 可选底部左侧操作，默认null；选择/上传期间屏蔽点击，回调及资源由调用方持有。
  /// 非null时优先于 [allowRemove] 提供的默认封面移除按钮，不随内容滚动。
  final Widget? leadingAction;

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
  late final _service = widget.service ?? (widget.useRuntimeService ? CollabRuntime.services.mediaUpload : null);

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

  /// 根据资源类型提供链接输入提示，不作为默认值或实际保存地址。
  String get _hint => switch (widget.kind) {
    'image' || 'document_banner' || 'document_icon' => '粘贴 https:// 开头的图片地址',
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
        setState(() => _error = e is FormatException ? e.message : '无法选择文件，请重试');
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
          (isCollabResourceType(widget.kind) && !isCollabResourceUrl(widget.kind, url))) {
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
        setState(() => _error = e is FormatException ? e.message : '上传失败，请检查网络后重试');
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

  /// 在借用 [context] 中展示来源分类与真实上传/图库内容，封面使用图片图标，固定头尾并统一键盘避让。
  /// 文件选择和上传保持可取消，销毁时仍由本状态取消令牌并忽略迟到结果。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    final upload = _service != null && editorMediaSupportsUpload(widget.kind);
    final title = widget.kind == 'document_icon'
        ? '修改图标'
        : _banner
        ? '修改封面'
        : '添加$_label';
    return CollabBottomSheet(
      title: Text(title),
      subtitle: _banner
          ? '为文档挑选一张合适的封面'
          : widget.kind == 'document_icon'
          ? '一个小图标，让文档更容易找到'
          : '选择$_label来源，丰富文档内容',
      icon: _banner
          ? LucideIcons.image
          : widget.kind == 'document_icon'
          ? LucideIcons.smile
          : switch (widget.kind) {
              'image' => LucideIcons.image,
              'video' => LucideIcons.video,
              'audio' => LucideIcons.audioLines,
              _ => LucideIcons.paperclip,
            },
      closeKey: const ValueKey('editor-media-source-close'),
      scrollController: _banner ? _bannerScroll : null,
      expand: _hasFirstTab,
      scrollBody: !(_source == 'first' && widget.firstTabOwnsScroll),
      scrollKey: ValueKey('editor-${widget.kind}-source-sheet'),
      header: Padding(
        key: _banner ? const ValueKey('document-cover-source-header') : null,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (upload || _hasFirstTab)
              CollabModalSegments<String>(
                values: {
                  if (_hasFirstTab) 'first': _banner ? '公共图库' : widget.firstTabLabel!,
                  if (_hasFirstTab) 'upload': '上传图片',
                  'link': _hasFirstTab ? '图片链接' : '$_label链接',
                  if (!_hasFirstTab) 'upload': '本地上传',
                },
                selected: _source,
                itemKeys: {
                  'first': ValueKey(_banner ? 'document-cover-library-tab' : 'document-icon-emoji-tab'),
                  'upload': const ValueKey('editor-media-upload-tab'),
                  'link': const ValueKey('editor-media-link-tab'),
                },
                onSelected: _busy
                    ? null
                    : (source) {
                        FocusScope.of(context).unfocus();
                        if (_banner && _bannerScroll.hasClients) {
                          _bannerScroll.jumpTo(0);
                        }
                        setState(() {
                          _source = source;
                          _error = null;
                        });
                      },
              ),
          ],
        ),
      ),
      leadingAction: widget.leadingAction != null
          ? IgnorePointer(
              ignoring: _busy,
              child: Opacity(opacity: _busy ? .4 : 1, child: widget.leadingAction!),
            )
          : widget.allowRemove
          ? TextButton(
              key: const ValueKey('editor-cover-url-remove'),
              style: TextButton.styleFrom(foregroundColor: c.danger),
              onPressed: _busy
                  ? null
                  : () {
                      if (_checkEditable()) {
                        _complete(const EditorMediaSource(''));
                      }
                    },
              child: const Text('移除封面'),
            )
          : null,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        if (_source == 'first') FilledButton(onPressed: () => Navigator.pop(context), child: const Text('完成')),
        if (_source != 'first')
          FilledButton(
            key: const ValueKey('editor-url-block-submit'),
            onPressed: _busy || (_local ? _file == null : _url.text.trim().isEmpty) ? null : _submit,
            child: Text(
              _uploading
                  ? '上传中…'
                  : _local
                  ? (widget.kind == 'document_icon' || _banner ? '上传并保存' : '上传并插入')
                  : (widget.kind == 'document_icon' || _banner ? '保存' : '插入$_label'),
            ),
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_source == 'first')
            if (widget.firstTabOwnsScroll)
              Expanded(child: widget.firstTab!)
            else
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
            CollabModalField(
              label: '$_label链接',
              child: TextField(
                key: const ValueKey('editor-url-block-input'),
                controller: _url,
                focusNode: _urlFocus,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(hintText: _hint),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
              ),
            ),
            Text(
              widget.kind == 'image' ? '支持 JPG、PNG、GIF、WebP 等常见图片格式' : '支持可直接访问的$_label链接',
              style: TextStyle(fontSize: 11, color: c.muted),
            ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(10)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.info, size: 16, color: c.accent),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text('使用网络$_label时，请确保链接可被文档成员访问。', style: TextStyle(fontSize: 12, color: c.accent)),
                  ),
                ],
              ),
            ),
          ] else ...[
            Material(
              color: c.field,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                key: const ValueKey('editor-media-pick-file'),
                onTap: _busy || !upload ? null : _pick,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
                  decoration: BoxDecoration(
                    border: Border.all(color: c.line),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Icon(_file == null ? LucideIcons.cloudUpload : LucideIcons.fileImage, size: 28, color: c.accent),
                      const SizedBox(height: 8),
                      Text(
                        _picking ? '正在选择文件…' : (_file?.name ?? '点击选择$_label文件'),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _file == null
                            ? (upload ? _fileHint : (_banner ? '当前环境暂不支持图片上传，请使用图库或链接' : '当前环境暂不支持图片上传，请使用表情或链接'))
                            : '${(_file!.size / 1024 / 1024).toStringAsFixed(2)} MB · 点击重新选择',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: c.muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_uploading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress, color: c.accent, borderRadius: BorderRadius.circular(3)),
              const SizedBox(height: 8),
              Text(
                _progress >= 1 ? '正在保存文件…' : '正在上传 ${(_progress * 100).round()}%',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: c.muted),
              ),
            ],
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                key: const ValueKey('editor-media-source-error'),
                style: TextStyle(fontSize: 12, color: c.danger),
              ),
            ),
        ],
      ),
    );
  }
}
