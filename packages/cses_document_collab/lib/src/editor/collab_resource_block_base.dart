import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_resource_settings.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 资源卡片的共同节点契约；具体音频、附件或网页组件负责自己的展示和资源。
///
/// 此类型仅供包内块实现继承，不拥有编辑器、网络请求或播放控制器。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_audio_block.dart';
/// final audioBuilder = CollabAudioBlockComponentBuilder();
/// // 在 AppFlowyEditor.blockComponentBuilders['audio'] 注册。
/// ```
abstract class CollabResourceBlock extends BlockComponentStatefulWidget {
  /// [key]控制身份与状态复用；[node]及[configuration]由编辑器创建并持有。
  const CollabResourceBlock({super.key, required super.node, required super.configuration});
}

/// 资源块共同的选区与操作状态；不分派资源类型，也不持有媒体控制器。
///
/// [T]为具体资源组件；其状态实现[resourceLabel]与[buildResourceCard]。
/// 监听与文档均借用编辑器，菜单沿用稳定身份、权限和内容失效检查。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_attachment_block.dart';
/// final attachmentBuilder = CollabAttachmentBlockComponentBuilder();
/// // 在 AppFlowyEditor.blockComponentBuilders['attachment'] 注册。
/// ```
abstract class CollabResourceBlockState<T extends CollabResourceBlock> extends State<T> with SelectableMixin {
  /// 具体卡片实际外框的视觉边界；由当前State创建，随组件释放。
  final bodyKey = GlobalKey();

  /// 借用的编辑器，仅在首次使用时解析，不能由资源组件释放。
  late final EditorState editor = context.read<EditorState>();

  /// 当前节点的HTTP(S)地址；随节点更新即时读取，不缓存旧文档内容。
  String get url => widget.node.attributes[csesEmbedUrlAttribute] as String? ?? '';

  /// 稳定协同块身份；旧节点未提供时回退到AppFlowy节点身份。
  String get blockId =>
      widget.node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] as String? ?? widget.node.id;

  /// 当前节点的资源属性快照，不拥有或修改其底层共享数据。
  CollabResource get resource => CollabResource.fromAttributes(widget.node.attributes);

  /// 当前资源类型的展示名称，由具体块提供，供菜单与设置标题使用。
  String get resourceLabel;

  /// 在借用[context]中构建具体卡片；实际外框须绑定[bodyKey]以供整块选区定位。
  Widget buildResourceCard(BuildContext context);

  /// 在借用[context]中监听编辑权限，并包装具体卡片的整块选区与远端选中展示。
  /// ListenableBuilder自行解绑权限监听；具体子组件继续管理其媒体或平台视图。
  @override
  Widget build(BuildContext context) => BlockSelectionContainer(
    node: widget.node,
    delegate: this,
    listenable: editor.selectionNotifier,
    remoteSelection: editor.remoteSelections,
    blockColor: editor.editorStyle.selectionColor,
    supportTypes: const [BlockSelectionType.block],
    selectionAboveBlock: true,
    child: ListenableBuilder(listenable: editor.editableNotifier, builder: (context, _) => buildResourceCard(context)),
  );

  /// 通过借用[context]打开当前地址；导航失败显示提示，不抛出未处理的点击异常。
  /// 异步打开完成后只在该上下文仍有效时提示，不修改文档或恢复正文输入。
  Future<void> openResource(BuildContext context) async {
    final target = url;
    try {
      final uri = Uri.tryParse(target);
      if (uri != null &&
          isCollabResourceUrl('embed', target) &&
          await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (_) {
      // 打开失败统一通过下方提示展示。
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('无法打开此资源，请检查链接')));
    }
  }

  /// 为借用的当前[source]打开共用设置；调用方须先复核菜单身份与权限。
  /// 由稳定宿主上下文持有弹窗，等待其完整退场；字段控制器由弹窗创建和释放。
  Future<void> editResource(Node source) async {
    await showCollabResourceSettings(
      collabBlockActionContext(context),
      editor: editor,
      node: source,
      label: resourceLabel,
    );
  }

  /// 删除借用的[source]，省略时使用当前节点；关闭、只读、已删除或身份过期时忽略。
  /// 末个根/高亮子块补稳定身份空段落，删除和补段落保持同一独立撤销事务。
  Future<void> deleteResource([Node? source]) async {
    if (!editor.editable || editor.isDisposed || (source ?? widget.node).parent == null) {
      return;
    }
    final node = source ?? widget.node;
    if (!identical(findCollabActionNode(editor, node.attributes['cses_collab_block_id'] as String? ?? node.id), node)) {
      return;
    }
    if (editor.undoManager.undoStack.isNonEmpty) {
      editor.undoManager.undoStack.last.seal();
    }
    final path = node.path;
    final parent = node.parent!;
    final transaction = editor.transaction..deleteNode(node);
    if (parent.children.length == 1 && const {'page', 'callout'}.contains(parent.type)) {
      final paragraph = paragraphNode();
      paragraph.updateAttributes({AppFlowyBlockEditorAdapter.collabBlockIdAttribute: paragraph.id});
      transaction.add(InsertOperation(path, [paragraph]), transform: false);
      transaction.afterSelection = Selection.single(path: path, startOffset: 0);
    } else {
      transaction.afterSelection = null;
    }
    await editor.apply(transaction, skipHistoryDebounce: true);
  }

  /// 构建音频/附件共用菜单；[openLabel]为外部打开项标题，权限与只读显隐由具体卡片决定。
  /// 音频菜单提供复制完整链接；编辑、复制与删除在菜单退场后重新解析稳定块身份，拒绝过期目标。
  /// 不拥有借用的回调资源，附件保留既有命令。
  Widget buildResourceMore({required String openLabel}) {
    final host = collabBlockActionContext(context);
    final id = blockId;
    return CollabBlockMoreButton(
      key: ValueKey('block-more-$id'),
      editor: editor,
      node: widget.node,
      readOnlyActions: [(label: openLabel, key: ValueKey('resource-open-$id'), run: () => openResource(host))],
      actions: [
        if (widget.node.type == 'audio' && url.trim().isNotEmpty)
          (
            label: '复制链接',
            key: ValueKey('media-copy-link-$id'),
            run: () => copyCollabMediaLink(host, editor, widget.node),
          ),
        (
          label: '修改$resourceLabel',
          key: ValueKey('resource-edit-$id'),
          run: () async {
            final source = findCollabActionNode(editor, id);
            if (source != null) await editResource(source);
          },
        ),
        (
          label: '删除$resourceLabel',
          key: ValueKey('resource-delete-$id'),
          run: () async {
            final source = findCollabActionNode(editor, id);
            if (source != null) await deleteResource(source);
          },
        ),
      ],
    );
  }

  /// 返回当前节点的整块起点。
  @override
  Position start() => Position(path: widget.node.path);

  /// 返回当前节点的虚拟整块终点。
  @override
  Position end() => Position(path: widget.node.path, offset: 1);

  /// 无正文的资源将[pos]映射为整块终点。
  @override
  Position getPositionInOffset(Offset pos) => end();

  /// 资源卡片不展示正文光标。
  @override
  bool get shouldCursorBlink => false;

  /// 资源通过覆盖整个外框展示选中状态。
  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  /// 返回实际外框在组件内的矩形；[shiftWithBaseOffset]沿用组件原点约定。
  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) {
    final outer = context.findRenderObject();
    final inner = bodyKey.currentContext?.findRenderObject();
    if (outer is! RenderBox || inner is! RenderBox) return Rect.zero;
    return inner.localToGlobal(Offset.zero, ancestor: outer) & inner.size;
  }

  /// [position]只对应整块；[shiftWithBaseOffset]保持组件内坐标约定。
  @override
  Rect? getCursorRectInPosition(Position position, {bool shiftWithBaseOffset = false}) => getBlockRect();

  /// [selection]统一返回整块矩形；[shiftWithBaseOffset]保持组件内坐标约定。
  @override
  List<Rect> getRectsInSelection(Selection selection, {bool shiftWithBaseOffset = false}) => [getBlockRect()];

  /// 将[start]与[end]拖选范围映射为当前卡片的整块选区。
  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);

  /// 将[offset]转为全局坐标；[shiftWithBaseOffset]保持组件内坐标约定。
  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      (context.findRenderObject() as RenderBox).localToGlobal(offset);
}
