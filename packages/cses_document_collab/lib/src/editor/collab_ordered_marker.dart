import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 复用 AppFlowy 列表组件的 iconBuilder 扩展点，按 Rust 投影绘制正式编号。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_ordered_marker.dart';
/// final builder = NumberedListBlockComponentBuilder(iconBuilder: buildCollabOrderedMarker);
/// ```
/// [context] 提供借用的 EditorState 样式；[node] 是当前列表项；[direction] 控制文字方向。
/// 正式列表在可编辑时点击序号弹出继续/重新编号菜单，选择后通过 AppFlowy 事务发布。
/// 不注册监听或持有资源。新建项尚未获得 Rust 投影时使用草稿的相邻序号，不开放正式菜单。
Widget buildCollabOrderedMarker(
  BuildContext context,
  Node node,
  TextDirection direction,
) {
  final state = context.read<EditorState>();
  final raw = node.attributes[csesOrderedAttribute];
  final value = raw is Map
      ? CollabOrdered.fromJson(Map<String, dynamic>.from(raw))
      : CollabOrdered(order: _draftOrder(node));
  final depth = node.attributes[csesBlockIndentAttribute] as int? ?? 0;
  final circle = value.markerStyle == 'o1';
  final style = state.editorStyle.textStyleConfiguration.text;
  final scale = state.editorStyle.textScaleFactor;
  final text = Text(
    value.marker(depth),
    style: style,
    textScaler: TextScaler.linear(scale),
    textDirection: direction,
    textHeightBehavior: const TextHeightBehavior(
      applyHeightToFirstAscent: false,
      applyHeightToLastDescent: false,
    ),
  );
  final marker = Container(
    constraints: BoxConstraints(minWidth: 26 * scale, minHeight: 22 * scale),
    padding: EdgeInsets.only(right: 4 * scale),
    child: Center(
      child: circle
          ? Container(
              padding: EdgeInsets.symmetric(horizontal: 4 * scale),
              decoration: BoxDecoration(
                border: Border.all(color: style.color ?? Colors.black),
                shape: BoxShape.circle,
              ),
              child: text,
            )
          : text,
    ),
  );
  if (raw is! Map || !state.editable) return marker;
  final id =
      node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute]
          as String?;
  if (id == null) return marker;
  // iconBuilder 提供的是整行组件的 context；使用序号自己的 context 锚定菜单，
  // 防止长正文或右对齐时菜单出现在整行另一端。
  return Builder(
    builder: (markerContext) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showNumberingMenu(markerContext, state, id),
      child: marker,
    ),
  );
}

/// 使用借用的 [context] 定位序号菜单；[state] 由宿主释放，[blockId] 是稳定协同身份。
/// 打开及提交时均重新检查节点、类型与可编辑性；取消菜单或页面销毁不产生写入。
/// 不主动移动选区或焦点；异步菜单异常由此边界记录并提示，Future 在操作结束后完成。
/// 菜单首选宽度220逻辑像素，以紧凑展示两种编号操作；窄屏仍由共用定位限幅。
Future<void> _showNumberingMenu(
  BuildContext context,
  EditorState state,
  String blockId,
) async {
  if (state.isDisposed || !state.editable || !context.mounted) return;
  final node = state.document.root.children
      .where(
        (n) =>
            n.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] ==
            blockId,
      )
      .firstOrNull;
  if (node == null || node.type != NumberedListBlockKeys.type) return;
  final raw = node.attributes[csesOrderedAttribute];
  if (raw is! Map) return;
  try {
    final value = CollabOrdered.fromJson(Map<String, dynamic>.from(raw))
        .withNumbering(
          node.attributes[csesOrderedNumberingAttribute] as String? ??
              raw['numbering'] as String? ??
              '{}',
        );
    final restart = await showCollabPopover<bool>(
      context: context,
      title: '列表编号',
      width: 220,
      builder: (_) => _NumberingMenu(value: value),
    );
    if (restart == null || !context.mounted) return;
    await changeCollabOrderedNumbering(state, blockId, restart: restart);
  } catch (error, stackTrace) {
    CollabDiagnostics.report(
      '有序列表编号操作失败',
      error: error,
      stackTrace: stackTrace,
      tag: 'DocCollab',
    );
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('编号操作失败，请重试')));
    }
  }
}

/// 只返回重开/接续请求的编号菜单，当前选项用勾选标识。
class _NumberingMenu extends StatelessWidget {
  /// [value] 为打开菜单时的编号属性快照。
  const _NumberingMenu({required this.value});

  /// 打开时借用的编号快照，菜单仅输出重开或接续请求。
  final CollabOrdered value;

  /// 在借用 [context] 中显示两种编号操作，不直接写入文档。
  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('collab-numbering-menu'),
    mainAxisSize: MainAxisSize.min,
    children: [
      _item(context, label: '重新编号', restart: true, selected: value.restarts),
      _item(
        context,
        label: '继续编号',
        restart: false,
        selected: value.continuesPrevious,
      ),
    ],
  );

  /// 为借用 [context] 返回 [restart] 请求；[label] 为名称，[selected] 为当前标记。
  Widget _item(
    BuildContext context, {
    required String label,
    required bool restart,
    required bool selected,
  }) => CollabMenuRow(
    selected: selected,
    key: ValueKey('collab-numbering-${restart ? 'restart' : 'continue'}'),
    leading: Icon(
      restart ? LucideIcons.listRestart : LucideIcons.listOrdered,
      size: 19,
    ),
    title: Text(label),
    trailing: selected ? const Icon(LucideIcons.check, size: 16) : null,
    onTap: () => Navigator.pop(context, restart),
  );
}

/// 对借用的草稿 [node] 计算相邻一基起始编号的零基序号；正式列表使用 Rust 投影。
/// 此回退仅覆盖根级新建节点的短暂展示，不将视觉编号写回原生 start/order。
int _draftOrder(Node node) {
  var order = 0;
  var previous = node.previous;
  while (previous != null && previous.type == NumberedListBlockKeys.type) {
    order++;
    final start = previous.attributes[NumberedListBlockKeys.number] as int?;
    if (start != null) return start + order - 1;
    previous = previous.previous;
  }
  return (node.attributes[NumberedListBlockKeys.number] as int? ?? 1) +
      order -
      1;
}
