import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 按稳定 [blockId] 查找 [editorState] 中当前图片，避免弹窗期间远端移动后使用旧 path。
/// 返回借用节点；已删除或类型变化时返回 null，不修改编辑器。
Node? _findImage(EditorState editorState, String blockId) => editorState
    .document
    .root
    .children
    .where(
      (n) =>
          n.type == ImageBlockKeys.type &&
          (n.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] ??
                  n.id) ==
              blockId,
    )
    .firstOrNull;

/// 从借用图片 [node] 读取正式投影；缺失或错误属性抛出 TypeError，调用方必须是正式图片。
CollabEditorBlock _snapshot(Node node) => CollabEditorBlock(
  id:
      (node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] ??
              node.id)
          as String,
  blockType: ImageBlockKeys.type,
  text: node.attributes[ImageBlockKeys.url] as String? ?? '',
  alignment: node.attributes[blockComponentAlign] as String? ?? 'left',
  image: CollabImage.fromJson(
    Map<String, dynamic>.from(node.attributes[collabImageAttribute] as Map),
  ),
);

/// 提交 [original] 到 [desired] 的图片编辑，只修改用户实际改变的字段。
/// [editorState] 为借用编辑器，调用方负责生命周期。只读或图片已删时返回 false；
/// 同一字段在弹窗期间被远端修改时抛出 StateError(IMAGE_EDIT_CONFLICT)，禁止旧表单覆盖新值。
/// Future 在单次 AppFlowy 事务完成后结束；事务由适配器发布给 Rust，不直接发送 WS。
/// 两份投影必须是同一 ID 的正式图片，且 image 非 null，否则抛出 ArgumentError。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
/// import 'package:cses_document_collab/src/editor/collab_image_editor.dart';
/// Future<bool> saveImage(EditorState editorState,
///     CollabEditorBlock original, CollabEditorBlock desired) =>
///     applyCollabImageEdit(editorState, original, desired);
/// ```
Future<bool> applyCollabImageEdit(
  EditorState editorState,
  CollabEditorBlock original,
  CollabEditorBlock desired,
) async {
  if (original.id != desired.id ||
      original.blockType != ImageBlockKeys.type ||
      desired.blockType != ImageBlockKeys.type ||
      original.image == null ||
      desired.image == null) {
    throw ArgumentError('需要同一正式图片的完整投影');
  }
  if (!editorState.editable) return false;
  final node = _findImage(editorState, original.id);
  if (node == null || node.attributes[collabImageAttribute] is! Map) {
    return false;
  }
  final current = _snapshot(node);
  final before = original.image!.toJson();
  final after = desired.image!.toJson();
  final merged = current.image!.toJson();
  for (final key in ['wr', 'ar', 'width', 'height', 'rotation']) {
    if (before[key] == after[key]) continue;
    if (merged[key] != before[key] && merged[key] != after[key]) {
      throw StateError('IMAGE_EDIT_CONFLICT');
    }
    merged[key] = after[key];
  }
  if (!listEquals(original.image!.captions, desired.image!.captions)) {
    if (!listEquals(current.image!.captions, original.image!.captions) &&
        !listEquals(current.image!.captions, desired.image!.captions)) {
      throw StateError('IMAGE_EDIT_CONFLICT');
    }
    merged['captions'] = after['captions'];
  }
  final attributes = <String, dynamic>{collabImageAttribute: merged};
  if (original.text != desired.text) {
    if (current.text != original.text && current.text != desired.text) {
      throw StateError('IMAGE_EDIT_CONFLICT');
    }
    attributes[ImageBlockKeys.url] = desired.text;
  }
  if (original.alignment != desired.alignment) {
    if (current.alignment != original.alignment &&
        current.alignment != desired.alignment) {
      throw StateError('IMAGE_EDIT_CONFLICT');
    }
    attributes[blockComponentAlign] = desired.alignment;
    attributes[ImageBlockKeys.align] = desired.alignment;
  }
  await editorState.apply(
    editorState.transaction..updateNode(node, attributes),
  );
  return true;
}

/// 删除借用 [editorState] 中 [blockId] 的图片，保留/创建后续正文供光标落点。
/// 只读或图片已删时返回 false；Future 在单次事务完成后结束，Rust 同步移除图片及其题注。
Future<bool> deleteCollabImage(EditorState editorState, String blockId) async {
  if (!editorState.editable) return false;
  final node = _findImage(editorState, blockId);
  if (node == null) return false;
  final transaction = editorState.transaction;
  final landingPath = node.path;
  if (node.next?.delta == null) {
    transaction.insertNode([node.path.first + 1], paragraphNode());
  }
  transaction.deleteNode(node);
  transaction.afterSelection = Selection.single(
    path: landingPath,
    startOffset: 0,
  );
  await editorState.apply(transaction);
  return true;
}

/// 为 [editorState] 中的正式图片 [node] 打开编辑表单；[context] 仅在当前调用期间借用。
/// [captionOnly] 默认 false，编辑链接与布局且保留原题注；true 时仅编辑题注，
/// 不改链接或布局。两个表单仅提供取消/保存，删除由卡片更多菜单处理。
/// 输入控制器由弹窗 State 持有并在退出过渡结束后释放。远端删除、只读或字段冲突时提示并放弃旧输入。
/// 预期冲突不记录异常；其他失败由此唯一边界记录原始 error/stackTrace 并提示。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_image_editor.dart';
/// import 'package:flutter/widgets.dart';
/// Future<void> editCaption(BuildContext context, EditorState editor, Node image) =>
///     showCollabImageEditor(context, editor, image, captionOnly: true);
/// // editor和image由页面持有，弹窗不释放它们。
/// ```
Future<void> showCollabImageEditor(
  BuildContext context,
  EditorState editorState,
  Node node, {
  bool captionOnly = false,
}) async {
  if (!editorState.editable) return;
  final original = _snapshot(node);
  try {
    final result = await showDialog<CollabEditorBlock>(
      context: context,
      builder: (_) =>
          _CollabImageEditDialog(original: original, captionOnly: captionOnly),
    );
    if (result == null || !context.mounted) return;
    final applied = await applyCollabImageEdit(editorState, original, result);
    if (!applied && context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('图片已删除或文档已进入只读，请重新查看')));
    }
  } catch (error, stackTrace) {
    final conflict =
        error is StateError && error.message == 'IMAGE_EDIT_CONFLICT';
    if (!conflict) {
      CollabDiagnostics.report(
        '图片编辑失败',
        error: error,
        stackTrace: stackTrace,
        tag: 'DocCollab',
      );
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(conflict ? '图片已被其他端修改，请重新打开编辑' : '图片编辑失败，请重试')),
      );
    }
  }
}

/// 图片编辑表单；持有打开时的原始投影，提交后由外层检查远端竞态。
class _CollabImageEditDialog extends StatefulWidget {
  /// [original] 为打开表单时的图片投影，借用且不修改；资源由 State 持有。
  /// [captionOnly] 决定仅编辑题注或仅编辑链接与布局，两种模式都保留未编辑字段。
  const _CollabImageEditDialog({
    required this.original,
    required this.captionOnly,
  });

  /// 弹窗打开时的不可变图片投影，用于检测并发字段冲突。
  final CollabEditorBlock original;

  /// true仅显示题注，false仅显示图片链接和布局。
  final bool captionOnly;

  /// 创建拥有输入控制器的表单状态。
  @override
  createState() => _CollabImageEditDialogState();
}

/// 控制器只在 State 生命周期内有效，关闭动画结束后统一释放。
class _CollabImageEditDialogState extends State<_CollabImageEditDialog> {
  late final TextEditingController url;
  late final TextEditingController wr;
  late final TextEditingController ar;
  late final List<CollabImageCaption> captions;
  late final List<TextEditingController> texts;
  late String alignment;
  String? errorText;

  /// 打开时的基准块，用于提交时只更新用户改动字段。
  CollabEditorBlock get original => widget.original;

  /// 原布局与题注；当前模式未展示的字段和rotation/旧尺寸原样保留。
  CollabImage get image => original.image!;

  /// 创建表单控制器，不连接网络或写入正文。
  @override
  void initState() {
    super.initState();
    url = TextEditingController(text: original.text);
    wr = TextEditingController(text: image.widthRatio?.toString() ?? '');
    ar = TextEditingController(text: image.aspectRatio?.toString() ?? '');
    captions = widget.captionOnly && image.captions.isEmpty
        ? [CollabImageCaption(id: CollabRuntime.services.newId(), text: '')]
        : image.captions;
    texts = captions
        .map((c) => TextEditingController(text: c.text))
        .toList(growable: false);
    alignment = original.alignment;
  }

  /// 使用 [context] 渲染表单；确认只返回投影，外层执行当前文档事务。
  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('collab-image-edit-dialog'),
    title: Text(
      widget.captionOnly ? (image.captions.isEmpty ? '添加题注' : '编辑题注') : '编辑图片',
    ),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.captionOnly) ...[
            TextField(
              key: const ValueKey('collab-image-url-input'),
              controller: url,
              decoration: const InputDecoration(labelText: '图片链接'),
              keyboardType: TextInputType.url,
            ),
            TextField(
              key: const ValueKey('collab-image-width-input'),
              controller: wr,
              decoration: const InputDecoration(
                labelText: '宽度百分比（0.1～100）',
                hintText: '默认 100',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            TextField(
              key: const ValueKey('collab-image-ratio-input'),
              controller: ar,
              decoration: const InputDecoration(
                labelText: '宽高比',
                hintText: '默认 4:3',
              ),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            DropdownButton<String>(
              value: alignment,
              isExpanded: true,
              items: const [
                DropdownMenuItem(value: 'left', child: Text('左对齐')),
                DropdownMenuItem(value: 'center', child: Text('居中')),
                DropdownMenuItem(value: 'right', child: Text('右对齐')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => alignment = value);
              },
            ),
          ],
          if (widget.captionOnly)
            for (var i = 0; i < texts.length; i++)
              TextField(
                key: ValueKey('collab-image-caption-input-$i'),
                controller: texts[i],
                maxLines: null,
                decoration: InputDecoration(
                  labelText: texts.length == 1 ? '题注（可选）' : '题注 ${i + 1}',
                ),
              ),
          if (errorText != null)
            Text(errorText!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('collab-image-save'),
        onPressed: () {
          final uri = Uri.tryParse(url.text.trim());
          final width = wr.text.trim().isEmpty
              ? null
              : double.tryParse(wr.text.trim());
          final ratio = ar.text.trim().isEmpty
              ? null
              : double.tryParse(ar.text.trim());
          // 已有 data:/blob: 原值可保留；主动替换只接受可被其他端访问的 HTTP(S) URL。
          if (!widget.captionOnly &&
              url.text.trim() != original.text &&
              (uri == null ||
                  !['http', 'https'].contains(uri.scheme) ||
                  uri.host.isEmpty)) {
            setState(() => errorText = '请输入完整的 http:// 或 https:// 图片链接');
            return;
          }
          if (!widget.captionOnly &&
              ((wr.text.trim().isNotEmpty &&
                      (width == null ||
                          !width.isFinite ||
                          width < 0.1 ||
                          width > 100)) ||
                  (ar.text.trim().isNotEmpty &&
                      (ratio == null || !ratio.isFinite || ratio <= 0)))) {
            setState(() => errorText = '请填写有效的宽度比例和正数宽高比');
            return;
          }
          Navigator.pop(
            context,
            CollabEditorBlock(
              id: original.id,
              blockType: ImageBlockKeys.type,
              text: widget.captionOnly ? original.text : url.text.trim(),
              alignment: widget.captionOnly ? original.alignment : alignment,
              image: CollabImage(
                widthRatio: widget.captionOnly ? image.widthRatio : width,
                aspectRatio: widget.captionOnly ? image.aspectRatio : ratio,
                width: image.width,
                height: image.height,
                rotation: image.rotation,
                captions: !widget.captionOnly
                    ? image.captions
                    : List.unmodifiable([
                        for (var i = 0; i < captions.length; i++)
                          if (image.captions.isNotEmpty ||
                              texts[i].text.isNotEmpty)
                            CollabImageCaption(
                              id: captions[i].id,
                              text: texts[i].text,
                            ),
                      ]),
              ),
            ),
          );
        },
        child: const Text('保存'),
      ),
    ],
  );

  /// 在弹窗真正移除后释放所有输入控制器，避免关闭过渡访问已释放对象。
  @override
  void dispose() {
    url.dispose();
    wr.dispose();
    ar.dispose();
    for (final controller in texts) {
      controller.dispose();
    }
    super.dispose();
  }
}
