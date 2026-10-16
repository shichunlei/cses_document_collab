import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:cses_document_collab/src/editor/collab_cached_image.dart';

import 'package:cses_document_collab/src/controller/document_metadata_controller.dart';
import 'package:cses_document_collab/src/model/document_metadata.dart';
import 'editor_media_source_sheet.dart';
import 'editor_shortcut_toolbar.dart';

/// 正式业务头部作为编辑器header滚动，始终独立于正文节点和正文撤销历史。
/// 借用控制器与编辑器；弹窗期间暂停正文输入，退场后恢复选区，再等待业务ACK。
/// 构建/显示不拥有网络客户端或控制器，销毁由宿主负责。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/controller/document_metadata_controller.dart';
/// import 'package:cses_document_collab/src/editor/document_header.dart';
/// DocumentHeader makeHeader(DocumentMetadataController metadata, EditorState editor) =>
///     DocumentHeader(controller: metadata, editorState: editor);
/// // 宿主使用前刷新metadata，退出时等待metadata.close()并释放editor。
/// ```
class DocumentHeader extends StatefulWidget {
  /// [key] 标识视图；[controller] 提供业务状态，[editorState] 提供正文焦点，均为必填借用对象。
  /// [preview] 默认false，为true时仅显示头部并隐藏编辑入口；构造不发请求。
  const DocumentHeader({
    super.key,
    required this.controller,
    required this.editorState,
    this.preview = false,
  });

  /// 标题、图标与正文共用的水平留白，封面不使用该内边距。
  static const contentInset = 20.0;

  /// 宿主拥有的头部状态，视图仅监听和发起获准的修改。
  final DocumentMetadataController controller;

  /// 宿主拥有的正文编辑状态，用于弹窗焦点和稳定块选区恢复。
  final EditorState editorState;

  /// 是否只展示业务头部；默认false，true时隐藏所有业务编辑入口。
  final bool preview;

  /// 创建仅拥有弹窗互斥标记的视图状态；业务资源继续由宿主持有。
  @override
  State<DocumentHeader> createState() => _DocumentHeaderState();
}

/// 将借用的业务快照渲染为头部，按当前权限执行单字段编辑，不创建正文块。
class _DocumentHeaderState extends State<DocumentHeader> {
  bool _modalOpen = false;

  /// 返回当前是否可执行外观操作，包含预览与提交状态，不修改业务权限。
  bool get _appearance =>
      !widget.preview && widget.controller.canChangeAppearance;

  /// 返回当前是否可执行改名，包含预览与提交状态，不发请求。
  bool get _rename => !widget.preview && widget.controller.canRename;

  /// 独立于提交状态决定是否保留改名操作位置，保持等待ACK期间的标题宽度。
  bool get _showRenameAction =>
      !widget.preview &&
      widget.controller.canEdit() &&
      widget.controller.value?.canRename == true;

  /// 独立于提交状态保留外观操作位置；真正点击仍使用执行门禁。
  bool get _showAppearanceActions =>
      !widget.preview &&
      widget.controller.canEdit() &&
      widget.controller.value?.canChangeAppearance == true;

  /// 对 [field] 执行name/icon/banner/removeBanner/position之一的单字段操作。
  /// 同时只允许一个操作；异步结果重新检查页面、实例与权限，取消/失效不提交。
  /// Future等待弹窗退场、正文选区恢复和业务ACK；业务失败由控制器状态及提示呈现。
  Future<void> _edit(String field) async {
    if (_modalOpen || (field == 'name' ? !_rename : !_appearance)) return;
    final controller = widget.controller;
    bool allowed() =>
        mounted &&
        identical(controller, widget.controller) &&
        (field == 'name' ? _rename : _appearance);
    final current = controller.value!;
    _modalOpen = true;
    try {
      final patch = await runEditorHeaderAction<DocumentMetadataPatch>(
        context,
        widget.editorState,
        () async {
          DocumentMetadataPatch? patch;
          if (field == 'banner') {
            final source = await showEditorMediaSourceSheet(
              context,
              blockType: 'document_banner',
              initialValue: current.banner?['url'] as String? ?? '',
              allowRemove: current.banner != null,
              canEdit: allowed,
            );
            if (source != null) {
              patch = DocumentMetadataPatch.banner(
                source.url.isEmpty
                    ? null
                    : {...?current.banner, 'url': source.url, 'y': 0},
              );
            }
          } else if (field == 'removeBanner') {
            patch = const DocumentMetadataPatch.banner(null);
          } else if (field == 'position') {
            patch = await _sheet<DocumentMetadataPatch>(
              context,
              _BannerPositionSheet(banner: current.banner!),
            );
          } else if (field == 'icon') {
            patch = await _sheet<DocumentMetadataPatch>(
              context,
              _IconSheet(icon: current.icon, canEdit: allowed),
              wrapContent: false,
            );
          } else {
            patch = await _sheet<DocumentMetadataPatch>(
              context,
              _TitleSheet(value: current.name),
            );
          }
          if (patch == null || !allowed()) return null;
          return patch;
        },
      );
      if (patch != null && allowed()) {
        // 弹窗退场后先恢复正文输入；业务 ACK 等待不占用正文焦点。
        await controller.save(patch);
        if (mounted && controller.error != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(controller.error!)));
        }
      }
    } finally {
      _modalOpen = false;
    }
  }

  /// 用业务 [value] 渲染48px图标占位，保持emoji/位图/SVG的下沿位置；点击按外观门禁执行。
  Widget _icon(Map<String, dynamic> value) => SizedBox.square(
    dimension: 48,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('document-icon-edit'),
        onTap: _appearance ? () => _edit('icon') : null,
        borderRadius: BorderRadius.circular(8),
        child: Center(child: _documentIcon(value)),
      ),
    ),
  );

  /// 封面铺满可用屏宽，图标三分之二叠在图内、三分之一露在正文区域。
  /// [banner] 为业务封面Map，[icon] 为null时不增加下沿占位；操作按图片中心定位。
  /// 返回受父宽度约束的视图，不修改业务数据；网络图片失败显示占位。
  Widget _cover(Map<String, dynamic> banner, Map<String, dynamic>? icon) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxWidth / 2.15;
          return SizedBox(
            height: height + (icon == null ? 0 : 16),
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: height,
                  child: Stack(
                    key: const ValueKey('document-banner-image'),
                    fit: StackFit.expand,
                    children: [
                      _bannerImage(banner),
                      if (_showAppearanceActions)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Material(
                              key: const ValueKey('document-banner-actions'),
                              color: const Color(0x99000000),
                              borderRadius: BorderRadius.circular(8),
                              child: Wrap(
                                alignment: WrapAlignment.center,
                                children: [
                                  for (final action in [
                                    ('banner', 'document-banner-edit', '更换封面'),
                                    (
                                      'removeBanner',
                                      'document-banner-remove',
                                      '移除封面',
                                    ),
                                    (
                                      'position',
                                      'document-banner-position',
                                      '调整位置',
                                    ),
                                  ])
                                    TextButton(
                                      key: ValueKey(action.$2),
                                      style: TextButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        minimumSize: const Size(0, 44),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 8,
                                        ),
                                      ),
                                      onPressed: _appearance
                                          ? () => _edit(action.$1)
                                          : null,
                                      child: Text(action.$3),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (icon != null)
                  Positioned(
                    left: DocumentHeader.contentInset,
                    top: height - 32,
                    child: _icon(icon),
                  ),
              ],
            ),
          );
        },
      );

  /// 在 [context] 中监听借用的控制器，仅重建头部；加载/保存失败以状态展示，保存中保留操作布局。
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final data = controller.value;
      if (data == null) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            DocumentHeader.contentInset,
            16,
            DocumentHeader.contentInset,
            16,
          ),
          child: Row(
            children: [
              Expanded(child: Text(controller.error ?? '正在加载文档头部…')),
              if (controller.error != null)
                TextButton(
                  onPressed: controller.refresh,
                  child: const Text('重试'),
                ),
            ],
          ),
        );
      }
      final banner = data.banner;
      return Padding(
        key: const ValueKey('formal-document-header'),
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (banner != null) _cover(banner, data.icon),
            Padding(
              padding: EdgeInsets.fromLTRB(
                DocumentHeader.contentInset,
                banner == null ? 16 : 12,
                DocumentHeader.contentInset,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (banner == null && _showAppearanceActions)
                    TextButton.icon(
                      key: const ValueKey('document-banner-edit'),
                      onPressed: _appearance ? () => _edit('banner') : null,
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: const Text('添加封面'),
                    ),
                  if (banner == null && data.icon != null) _icon(data.icon!),
                  if (data.icon == null && _showAppearanceActions)
                    TextButton.icon(
                      key: const ValueKey('document-icon-edit'),
                      onPressed: _appearance ? () => _edit('icon') : null,
                      icon: const Icon(Icons.add_reaction_outlined, size: 18),
                      label: const Text('添加图标'),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            data.name.isEmpty ? '未命名文档' : data.name,
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                        ),
                        if (_showRenameAction)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: SizedBox.square(
                              key: const ValueKey('document-title-action'),
                              dimension: 18,
                              child: controller.saving
                                  ? const CircularProgressIndicator(
                                      key: ValueKey('document-title-saving'),
                                      strokeWidth: 2,
                                      semanticsLabel: '正在保存文档头部',
                                    )
                                  : GestureDetector(
                                      key: const ValueKey(
                                        'document-title-edit',
                                      ),
                                      onTap: _rename
                                          ? () => _edit('name')
                                          : null,
                                      behavior: HitTestBehavior.translucent,
                                      child: const Icon(
                                        Icons.edit_outlined,
                                        size: 18,
                                        color: Colors.grey,
                                      ),
                                    ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  if (controller.error != null)
                    Text(
                      controller.error!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 使用 [context] 展示借用的 [child] 底部面板；[wrapContent] 默认true，为false时由child管理滚动/键盘。
/// Future等待弹窗完整退场再返回其结果，取消为null；调用方随后归还正文焦点，Navigator异常透传。
Future<T?> _sheet<T>(
  BuildContext context,
  Widget child, {
  bool wrapContent = true,
}) async {
  ModalRoute<T>? route;
  final result = await showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    requestFocus: true,
    builder: (context) {
      route = ModalRoute.of<T>(context);
      if (!wrapContent) return child;
      return AnimatedPadding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        duration: const Duration(milliseconds: 120),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: child,
        ),
      );
    },
  );
  await route?.completed;
  return result;
}

/// 根据业务 [banner] 的url及0～100百分比y展示裁切图片；异常y钳制到合法范围。
/// HTTP(S)位图及SVG共用图片文件缓存；非法地址或加载失败显示占位，不写业务数据。
Widget _bannerImage(Map<String, dynamic> banner) {
  final y = banner['y'];
  final position = y is num ? y.toDouble().clamp(0, 100) : 0.0;
  final url = banner['url'];
  final uri = url is String ? Uri.tryParse(url) : null;
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty) {
    return const ColoredBox(
      color: Color(0xFFF1F5F9),
      child: Center(child: Icon(Icons.broken_image_outlined)),
    );
  }
  return CollabCachedImage(
    key: ValueKey('document-banner:$url'),
    url: url as String,
    fit: BoxFit.cover,
    alignment: Alignment(0, position / 50 - 1),
    loading: const ColoredBox(color: Color(0xFFF1F5F9)),
    failure: const ColoredBox(
      color: Color(0xFFF1F5F9),
      child: Center(child: Icon(Icons.broken_image_outlined)),
    ),
  );
}

/// 根据业务 icon.type 展示文字表情或缓存图片，SVG读取同一文件缓存后矢量解码，
/// [icon] 是借用的type/value Map；无后缀SVG在位图解码失败后检查缓存内容。
/// 图片加载失败和未知类型返回通用图标，原数据不修改；返回值适配48px父占位。
Widget _documentIcon(Map<String, dynamic> icon) {
  if (icon['type'] == 'emoji' && icon['value'] is String) {
    return FittedBox(
      child: Text(
        icon['value'] as String,
        style: const TextStyle(fontSize: 44),
      ),
    );
  }
  final uri = icon['value'] is String
      ? Uri.tryParse(icon['value'] as String)
      : null;
  if (icon['type'] == 'image' &&
      uri != null &&
      ['http', 'https'].contains(uri.scheme) &&
      uri.host.isNotEmpty) {
    return CollabCachedImage(
      key: ValueKey('document-icon:$uri'),
      url: uri.toString(),
      width: 48,
      height: 48,
      semanticsLabel: '文档图标',
      loading: const SizedBox.square(dimension: 48),
      failure: const SizedBox.square(
        dimension: 48,
        child: Icon(Icons.description_outlined, size: 44),
      ),
    );
  }
  return FittedBox(child: const Icon(Icons.description_outlined, size: 44));
}

/// 拥有标题输入与表单校验的底部面板，输出业务命令，不直接保存或编辑正文。
class _TitleSheet extends StatefulWidget {
  /// 用借用的当前名称 [value] 初始化独立输入；不发业务请求。
  const _TitleSheet({required this.value});

  /// 当前业务名称；输入副本由本面板的状态持有。
  final String value;

  /// 创建拥有输入控制器的面板状态，退场时释放。
  @override
  State<_TitleSheet> createState() => _TitleSheetState();
}

/// 持有标题输入副本，仅输出校验后的改名命令；原业务状态由外层控制器管理。
class _TitleSheetState extends State<_TitleSheet> {
  late final _text = TextEditingController(text: widget.value);
  final _form = GlobalKey<FormState>();

  /// 释放本面板拥有的输入控制器，不触碰宿主业务服务或正文。
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// 校验非空标题并去除首尾空白，成功关闭面板返回改名命令；失败保留输入，不发请求。
  void _submit() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, DocumentMetadataPatch.rename(_text.text.trim()));
  }

  /// 在 [context] 中构建最长100字符的标题表单；确认输出命令，取消返回null。
  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('修改标题', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextFormField(
          key: const ValueKey('document-title-input'),
          controller: _text,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(labelText: '文档标题'),
          validator: (value) =>
              value == null || value.trim().isEmpty ? '请输入内容' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          spacing: 10,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('document-header-submit'),
              onPressed: _submit,
              child: const Text('保存'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// 图标三种来源共用一层面板，借用共享图片选择逻辑；emoji直接选择，无表单或输入控制器。
class _IconSheet extends StatelessWidget {
  /// [icon] 为当前业务图标，null表示未设置；[canEdit] 是确认时读取的借用权限回调。
  const _IconSheet({required this.icon, required this.canEdit});

  /// 当前图标，仅用于预填图片链接；emoji展示为固定选择列表。
  final Map<String, dynamic>? icon;

  /// 输出命令前读取的权限门禁；false时保持面板，不提交。
  final bool Function() canEdit;

  /// 在面板 [context] 中输出列表emoji [value] 并关闭；权限失效时忽略，不执行网络保存。
  void _select(BuildContext context, String value) {
    if (!canEdit()) return;
    Navigator.pop(
      context,
      DocumentMetadataPatch.icon({'type': 'emoji', 'value': value}),
    );
  }

  /// 用 [context] 构建三Tab面板，输出emoji/image命令或null移除；文件和链接状态由来源面板持有。
  @override
  Widget build(BuildContext context) => EditorMediaSourcePanel(
    kind: 'document_icon',
    initialValue: icon?['type'] == 'image'
        ? (icon!['value'] ?? '').toString()
        : '',
    canEdit: canEdit,
    onSelected: (source) {
      if (!canEdit()) return;
      Navigator.pop(
        context,
        DocumentMetadataPatch.icon({'type': 'image', 'value': source.url}),
      );
    },
    firstTabLabel: '表情符号',
    tabAction: TextButton.icon(
      key: const ValueKey('document-icon-remove'),
      style: TextButton.styleFrom(foregroundColor: Colors.red),
      onPressed: () {
        if (canEdit()) {
          Navigator.pop(context, const DocumentMetadataPatch.icon(null));
        }
      },
      icon: const Icon(Icons.remove_circle_outline, size: 16),
      label: const Text('移除'),
    ),
    firstTab: Wrap(
      spacing: 8,
      children: [
        for (final emoji in [
          '😘',
          '😀',
          '📄',
          '📌',
          '⭐',
          '🚀',
          '🎯',
          '💡',
          '❤️',
          '✅',
          '📚',
          '🌈',
        ])
          TextButton(
            onPressed: () => _select(context, emoji),
            child: Text(emoji, style: const TextStyle(fontSize: 28)),
          ),
      ],
    ),
  );
}

/// 预览封面裁切位置的独立面板，仅输出位置命令，不直接写业务接口。
class _BannerPositionSheet extends StatefulWidget {
  /// 借用当前 [banner] Map初始化位置，未知字段在确认命令中保留。
  const _BannerPositionSheet({required this.banner});

  /// 当前业务封面；面板仅持有y的编辑副本，不修改此Map。
  final Map<String, dynamic> banner;

  /// 创建仅持有位置副本的状态，不拥有图片或网络服务。
  @override
  State<_BannerPositionSheet> createState() => _BannerPositionSheetState();
}

/// 将y限制在0～100并预览，确认时输出保留原字段的位置命令。
class _BannerPositionSheetState extends State<_BannerPositionSheet> {
  late double _y =
      (widget.banner['y'] is num ? (widget.banner['y'] as num).toDouble() : 0.0)
          .clamp(0.0, 100.0);

  /// 在 [context] 中构建裁切预览与滑条；确认输出业务命令，取消返回null，均不发请求。
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('调整封面位置', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 16),
      AspectRatio(
        aspectRatio: 2.15,
        child: _bannerImage({...widget.banner, 'y': _y}),
      ),
      Slider(
        key: const ValueKey('document-banner-position-slider'),
        value: _y,
        min: 0,
        max: 100,
        divisions: 100,
        onChanged: (value) => setState(() => _y = value),
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        spacing: 10,
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('document-header-submit'),
            onPressed: () => Navigator.pop(
              context,
              DocumentMetadataPatch.banner({...widget.banner, 'y': _y.round()}),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    ],
  );
}
