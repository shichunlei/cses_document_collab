import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart' show csesEmbedUrlAttribute;
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/ui/modal/collab_block_lock_scope.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 判断借用[uri]是否为原媒体支持的HTTP(S)网络地址；不添加新的协议或来源限制。
bool isCollabMediaNetworkUri(Uri uri) => (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

/// 图片、视频和旧独立链接共用的节点配置，不创建播放器或拥有编辑器。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_image_block.dart';
/// final builder = CollabImageBlockComponentBuilder();
/// // 注册到 AppFlowyEditor.blockComponentBuilders['image']。
/// ```
abstract class CollabMediaBlock extends BlockComponentStatefulWidget {
  /// [key]控制身份复用；[node]及[configuration]借用编辑器。
  /// [showActions]决定是否包装块工具栏，[actionBuilder]和[actionTrailingBuilder]
  /// 为借用的原有工具栏回调；不转移回调或编辑器所有权。
  const CollabMediaBlock({
    super.key,
    required super.node,
    required super.configuration,
    super.showActions,
    super.actionBuilder,
    super.actionTrailingBuilder,
  });
}

/// 原媒体块的共用选区、配置与操作外壳，保持原Padding/Stack结构和选区类型。
///
/// [T]为具体媒体组件，子类实现[buildMedia]并按需提供[buildMediaActions]。
/// 本类只持有视觉定位键；媒体资源仍由具体子类或内容组件创建和释放。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_video_block.dart';
/// final builder = CollabVideoBlockComponentBuilder();
/// // 注册到 AppFlowyEditor.blockComponentBuilders['video']。
/// ```
abstract class CollabMediaBlockState<T extends CollabMediaBlock> extends State<T>
    with SelectableMixin, BlockComponentConfigurable {
  /// 当前State独有的原媒体Padding边界，供整块选区计算使用。
  final GlobalKey _contentKey = GlobalKey();

  /// 借用具体组件的原有布局配置，不修改或释放它。
  @override
  BlockComponentConfiguration get configuration => widget.configuration;

  /// 当前编辑器节点，不缓存其可变属性。
  @override
  Node get node => widget.node;

  /// 原媒体URL属性，未提供时为空；地址校验由各具体块保持原规则。
  String get url => node.attributes[csesEmbedUrlAttribute] as String? ?? '';

  /// 当前组件已挂载的渲染边界，未形成RenderBox时为空。
  RenderBox? get _renderBox => context.findRenderObject() as RenderBox?;

  /// 使用借用[context]创建具体媒体内容，不改变原卡片业务及UI。
  Widget buildMedia(BuildContext context);

  /// 返回借用[context]中原有的叠放操作层，默认null；图片继续使用内容组件自己的菜单。
  Widget? buildMediaActions(BuildContext context) => null;

  /// 在借用[context]中创建原位置的更多菜单；[readOnlyActions]默认空，供预览可用操作。
  /// [actions]默认空，仅编辑状态显示；回调由业务持有，在完整退场且身份/权限有效时执行。
  /// 菜单复用稳定身份及事务失效保护，不接管回调中的编辑器或播放器资源。
  Widget buildMediaMore(
    BuildContext context, {
    List<({String label, Key? key, Future<void> Function() run})> readOnlyActions = const [],
    List<({String label, Key? key, Future<void> Function() run})> actions = const [],
  }) => Positioned(
    top: 4,
    right: 4,
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(6),
      child: CollabBlockMoreButton(
        key: ValueKey('block-more-${node.attributes['cses_collab_block_id'] ?? node.id}'),
        editor: context.read<EditorState>(),
        node: node,
        readOnlyActions: readOnlyActions,
        actions: actions,
      ),
    ),
  );

  /// 使用借用[context]的编辑器渲染原外壳；不增加标题栏、背景或新的业务操作。
  /// 叠放层允许媒体自身的右上角锁标越过边缘，保留内容组件内部的圆角裁切。
  /// 带锁的首个根级媒体额外预留6像素顶部空间，避免锁标被编辑器滚动视口裁掉。
  @override
  Widget build(BuildContext context) {
    final editorState = context.read<EditorState>();
    final child = buildMedia(context);
    final actions = buildMediaActions(context);
    final firstLockedMedia =
        node.path.length == 1 && node.path.single == 0 && CollabBlockLockScope.maybeOf(context)?.showBadge == true;
    Widget selectableChild = Padding(
      key: _contentKey,
      padding: padding + (firstLockedMedia ? const EdgeInsets.only(top: 6) : EdgeInsets.zero),
      child: Stack(clipBehavior: Clip.none, children: [child, ?actions]),
    );
    selectableChild = BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editorState.selectionNotifier,
      remoteSelection: editorState.remoteSelections,
      blockColor: editorState.editorStyle.selectionColor,
      cursorColor: editorState.editorStyle.cursorColor,
      selectionColor: editorState.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block, BlockSelectionType.cursor, BlockSelectionType.selection],
      child: selectableChild,
    );
    if (widget.showActions && widget.actionBuilder != null) {
      selectableChild = BlockComponentActionWrapper(
        node: node,
        actionBuilder: widget.actionBuilder!,
        actionTrailingBuilder: widget.actionTrailingBuilder,
        child: selectableChild,
      );
    }
    return selectableChild;
  }

  /// 通过借用[context]在外部应用打开原地址；失败语义沿用原媒体实现，异常交给菜单调用方。
  Future<void> openExternally(BuildContext context) async {
    final uri = Uri.tryParse(url);
    final opened =
        uri != null && isCollabMediaNetworkUri(uri) && await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('无法打开该链接')));
    }
  }

  /// 返回当前媒体的虚拟整块起点。
  @override
  Position start() => Position(path: node.path, offset: 0);

  /// 返回当前媒体的虚拟整块终点。
  @override
  Position end() => Position(path: node.path, offset: 1);

  /// 将无正文媒体中的[offset]映射为整块终点。
  @override
  Position getPositionInOffset(Offset offset) => end();

  /// 媒体块不显示闪烁的正文光标。
  @override
  bool get shouldCursorBlink => false;

  /// 沿用原媒体的整块覆盖光标。
  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  /// 返回原内容矩形；[shiftWithBaseOffset]沿用原组件坐标约定。
  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) => getRectsInSelection(Selection.invalid()).first;

  /// 返回[position]所在矩形；[shiftWithBaseOffset]决定是否加入原内容的局部偏移。
  /// 未挂载RenderBox时返回null。
  @override
  Rect? getCursorRectInPosition(Position position, {bool shiftWithBaseOffset = false}) {
    if (_renderBox == null) return null;
    return getRectsInSelection(Selection.collapsed(position), shiftWithBaseOffset: shiftWithBaseOffset).firstOrNull;
  }

  /// 为[selection]返回原内容边界；[shiftWithBaseOffset]为true时加入内容相对组件的偏移。
  /// 未挂载时为空，内容边界尚不可用时回退到原组件尺寸。
  @override
  List<Rect> getRectsInSelection(Selection selection, {bool shiftWithBaseOffset = false}) {
    if (_renderBox == null) return const [];
    final parentBox = context.findRenderObject();
    final contentBox = _contentKey.currentContext?.findRenderObject();
    if (parentBox is RenderBox && contentBox is RenderBox) {
      final offset = shiftWithBaseOffset ? contentBox.localToGlobal(Offset.zero, ancestor: parentBox) : Offset.zero;
      return [offset & contentBox.size];
    }
    return [Offset.zero & _renderBox!.size];
  }

  /// 将[start]/[end]的拖选映射为当前媒体整块选区。
  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: node.path, startOffset: 0, endOffset: 1);

  /// 将[offset]转为全局坐标；[shiftWithBaseOffset]沿用原媒体约定，不另加偏移。
  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) => _renderBox!.localToGlobal(offset);

  /// 原媒体的虚拟选区始终使用从左至右方向。
  @override
  TextDirection textDirection() => TextDirection.ltr;
}
