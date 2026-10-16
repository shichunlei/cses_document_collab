import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_divider_visual.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';

/// 打开稳定 [id] 对应分割线的设置面板；借用 [context] 和 [editor]。
/// 正文输入在完整面板生命周期内隔离，退场动画完成后恢复原稳定选区。
/// 只读/删除/销毁时不打开；属性事务逐项保存，异常可见且保留诊断。
Future<void> showCollabDividerSettings(BuildContext context, EditorState editor, String id) async {
  if (!editor.editable || findCollabDivider(editor, id) == null) {
    return;
  }
  try {
    await runEditorHeaderAction<void>(context, editor, () async {
      ModalRoute<void>? route;
      await showModalBottomSheet<void>(
        context: context,
        useRootNavigator: false,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) {
          route = ModalRoute.of<void>(context);
          return _DividerSettings(editor: editor, id: id);
        },
      );
      await route?.completed;
    });
  } catch (error, stack) {
    CollabDiagnostics.report('分割线设置失败', error: error, stackTrace: stack, tag: 'DocCollab');
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('修改分割线失败，请重试')));
    }
  }
}

/// 面板借用编辑器，拥有节点/权限监听、设置区滚动控制器及局部外观状态。
class _DividerSettings extends StatefulWidget {
  /// [editor] 的生命周期长于面板，[id] 为稳定块身份，面板不关闭编辑器。
  const _DividerSettings({required this.editor, required this.id});

  /// 必需的借用编辑器，面板不创建或关闭其资源。
  final EditorState editor;

  /// 必需的稳定块身份，远端重排后重新查找目标。
  final String id;

  /// 创建局部状态，不创建网络/原生资源。
  @override
  State<_DividerSettings> createState() => _DividerSettingsState();
}

/// 监听权威树与目标属性，串行提交显式修改；关闭时解绑本面板监听。
class _DividerSettingsState extends State<_DividerSettings> {
  /// 最大胶带绘图高52逻辑像素，加上下各12像素留白，固定预览槽为76像素。
  /// 薄线和花边在槽内垂直居中，粗细、样式或目标删除均不改变头部布局。
  static const double _previewHeight = 52 + 12 * 2;

  /// 借用并监听目标及祖先；远端事务不经过 transactionStream，须直接观察节点。
  final Set<Node> _listenedNodes = {};
  int _tab = 0;

  /// 本面板持有的下方设置区滚动控制器；切换样式页归零，关闭时释放。
  final ScrollController _contentScrollController = ScrollController();

  /// 单次属性/删除提交期间拒绝新的写入，避免并发历史记录。
  bool _saving = false;

  /// 滑动期间的暂存值；松手只提交一次，避免每帧生成协同事务。
  double? _opacityDraft;
  String? _error;

  /// 解析当前稳定目标，删除或销毁返回 null，不缓存可能过期的 Node。
  CollabDivider? get _divider {
    final node = findCollabDivider(widget.editor, widget.id);
    return node == null ? null : CollabDivider(CollabDivider.readAttributes(node.attributes).values);
  }

  /// 绑定目标、祖先和编辑权限变化；远端更新、删除及权限撤销均可刷新面板。
  @override
  void initState() {
    super.initState();
    final style = _divider?.style ?? '';
    _tab = style.startsWith('tape-')
        ? 1
        : style.startsWith('edge-')
        ? 2
        : 0;
    _syncListeners();
    widget.editor.editableNotifier.addListener(_onTreeChanged);
  }

  /// 对最新目标和祖先建立借用监听，重排后解除旧节点，不关闭任何节点。
  void _syncListeners() {
    final next = <Node>{widget.editor.document.root};
    var node = findCollabDivider(widget.editor, widget.id);
    while (node != null) {
      next.add(node);
      node = node.parent;
    }
    for (final old in _listenedNodes.difference(next)) {
      old.removeListener(_onTreeChanged);
    }
    for (final added in next.difference(_listenedNodes)) {
      added.addListener(_onTreeChanged);
    }
    _listenedNodes
      ..clear()
      ..addAll(next);
  }

  /// 重新定位稳定目标并请求下一帧刷新；结构操作期间不写入或缓存临时节点。
  void _onTreeChanged() {
    if (!mounted || widget.editor.isDisposed) return;
    _syncListeners();
    setState(() {});
  }

  /// 在 [property] 上提交 [value] 的单字段修改；防止面板并发写入。
  /// 已失效目标或权限拒绝显示可理解的提示，失败不静默丢弃。
  Future<void> _change(String property, Object? value) async {
    if (_saving) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_divider == null || !widget.editor.editable || widget.editor.isDisposed) {
        if (mounted) {
          setState(() => _error = '分割线已删除或当前不可编辑');
        }
        return;
      }
      await changeCollabDividerProperty(widget.editor, widget.id, property, value);
    } catch (error, stack) {
      CollabDiagnostics.report('修改分割线失败', error: error, stackTrace: stack, tag: 'DocCollab');
      if (mounted) {
        setState(() => _error = '修改失败，请重试');
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _opacityDraft = null;
        });
      }
    }
  }

  /// 删除当前稳定目标，最后一个根块留下空段落；面板退出后由外层恢复焦点。
  Future<void> _delete() async {
    if (_saving || !widget.editor.editable) {
      return;
    }
    final node = findCollabDivider(widget.editor, widget.id);
    if (node == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final transaction = widget.editor.transaction..deleteNode(node);
      if (node.parent!.children.length == 1) {
        transaction.insertNode(node.path, paragraphNode());
      }
      if (widget.editor.undoManager.undoStack.isNonEmpty) {
        widget.editor.undoManager.undoStack.last.seal();
      }
      await widget.editor.apply(transaction, skipHistoryDebounce: true);
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (error, stack) {
      CollabDiagnostics.report('删除分割线失败', error: error, stackTrace: stack, tag: 'DocCollab');
      if (mounted) {
        setState(() => _error = '删除失败，请重试');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 解除节点及权限监听并释放本面板的滚动控制器；不关闭借用的编辑器或通知器。
  @override
  void dispose() {
    widget.editor.editableNotifier.removeListener(_onTreeChanged);
    for (final node in _listenedNodes) {
      node.removeListener(_onTreeChanged);
    }
    _listenedNodes.clear();
    _contentScrollController.dispose();
    super.dispose();
  }

  /// 选择 [values] 中唯一的样式页，下方滚动区归零以展示该页第一项。
  /// 不改共享属性或正文选区；固定头部保持可见，不创建或释放控制器。
  void _selectStyleTab(Set<int> values) {
    if (_contentScrollController.hasClients) {
      _contentScrollController.jumpTo(0);
    }
    setState(() => _tab = values.single);
  }

  /// 按 [context] 的屏幕/键盘约束渲染三页预设及立即保存的外观控件。
  /// 标题、预览及样式页切换固定，下方预设与外观设置使用剩余空间独立滚动。
  /// 预览槽固定为最大绘图高度加留白，实际分割线保持各档粗细并居中显示。
  /// 样式页以选中背景区分，不显示挤占标签宽度的勾选图标；三页名称始终完整单行。
  /// 贴纸胶带页隐藏不影响预设图案的线色控件；切换页不清除已有颜色属性。
  /// 清除与预设颜色使用一致的选中、可用状态和布局，重复选择不提交事务。
  @override
  Widget build(BuildContext context) {
    final divider = _divider;
    final enabled = divider != null && widget.editor.editable && !_saving;
    final current = divider ?? const CollabDivider({});
    final styles = collabDividerStyles.entries
        .where(
          (e) => _tab == 1
              ? e.key.startsWith('tape-')
              : _tab == 2
              ? e.key.startsWith('edge-')
              : !e.key.startsWith('tape-') && !e.key.startsWith('edge-'),
        )
        .toList();
    return SafeArea(
      top: false,
      child: SizedBox(
        key: const ValueKey('collab-divider-settings'),
        height: mathHeight(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              key: const ValueKey('divider-settings-header'),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('分割线', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      ),
                      IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                    ],
                  ),
                  SizedBox(
                    key: const ValueKey('divider-settings-preview'),
                    height: _previewHeight,
                    child: Center(
                      child: divider == null
                          ? const Text('分割线已删除')
                          : Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: CollabDividerVisual(divider: current),
                            ),
                    ),
                  ),
                  SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 0, label: _DividerStyleTabLabel('线型')),
                      ButtonSegment(value: 1, label: _DividerStyleTabLabel('贴纸胶带')),
                      ButtonSegment(value: 2, label: _DividerStyleTabLabel('花边')),
                    ],
                    selected: {_tab},
                    onSelectionChanged: _selectStyleTab,
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('divider-settings-content'),
                controller: _contentScrollController,
                padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: styles.length,
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisExtent: 56,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 8,
                      ),
                      itemBuilder: (context, index) {
                        final entry = styles[index];
                        return Semantics(
                          label: entry.value,
                          selected: current.style == entry.key,
                          button: true,
                          child: InkWell(
                            key: ValueKey('divider-style-${entry.key}'),
                            onTap: enabled ? () async => await _change('style', entry.key) : null,
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: current.style == entry.key
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).dividerColor,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: CollabDividerVisual(
                                divider: CollabDivider({'style': entry.key, 'lineColor': current.lineColor}),
                                preview: true,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    if (_tab != 1) ...[
                      const SizedBox(height: 16),
                      const Text('线色'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _colorOption('', current.lineColor, enabled),
                          for (final hex in const [
                            '#9CA3AF',
                            '#333333',
                            '#EF4444',
                            '#F59E0B',
                            '#22C55E',
                            '#3B82F6',
                            '#8B5CF6',
                            '#EC4899',
                          ])
                            _colorOption(hex, current.lineColor, enabled),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text('长度'),
                    _options('length', current.length, const {
                      'short': '短',
                      'medium': '中',
                      'long': '长',
                      'full': '通栏',
                    }, enabled),
                    const SizedBox(height: 12),
                    const Text('粗细'),
                    _options('thickness', current.thickness, const {
                      'thin': '细',
                      'regular': '常规',
                      'thick': '粗',
                    }, enabled),
                    const SizedBox(height: 12),
                    Text('透明度 ${((_opacityDraft ?? current.opacity) * 100).round()}%'),
                    Slider(
                      key: const ValueKey('divider-opacity'),
                      value: _opacityDraft ?? current.opacity,
                      min: .1,
                      max: 1,
                      divisions: 90,
                      onChanged: enabled ? (value) => setState(() => _opacityDraft = value) : null,
                      onChangeEnd: enabled ? (value) async => await _change('opacity', value) : null,
                    ),
                    if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    TextButton.icon(
                      key: const ValueKey('divider-delete'),
                      onPressed: enabled ? _delete : null,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('删除分割线'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建 [value] 对应的36px色块，空字符串表示清除颜色，其他值为预设HEX颜色。
  /// [currentColor] 是借用的当前颜色，按解析后的颜色匹配预设，空白值选中清除块。
  /// [enabled] 控制交互和无障碍可用状态；选中项重复点击不写入、不生成历史。
  /// 返回拥有提示及选中边框的Widget，点击仅提交lineColor，不修改其他属性。
  Widget _colorOption(String value, String currentColor, bool enabled) {
    final clear = value.isEmpty;
    final color = parseCollabBlockColor(value);
    final selected = clear
        ? currentColor.trim().isEmpty
        : color != null && parseCollabBlockColor(currentColor) == color;
    final label = clear ? '清除颜色' : '线色 $value';
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        label: label,
        selected: selected,
        enabled: enabled,
        button: true,
        child: InkWell(
          key: ValueKey(clear ? 'divider-color-clear' : 'divider-color-$value'),
          onTap: enabled
              ? () async {
                  if (!selected) {
                    await _change('lineColor', value);
                  }
                }
              : null,
          child: Opacity(
            opacity: enabled ? 1 : .38,
            child: Container(
              width: 36,
              height: 36,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: clear ? Alignment.center : null,
              child: clear
                  ? const Icon(Icons.clear, size: 20)
                  : DecoratedBox(
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5)),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// [property] 控件按 [selected] 展示，[options] 提供键/标签；[enabled] 控制写入。
  Widget _options(String property, String selected, Map<String, String> options, bool enabled) =>
      SegmentedButton<String>(
        segments: [
          for (final e in options.entries)
            ButtonSegment(
              value: e.key,
              label: Text(e.value, key: ValueKey('divider-$property-${e.key}')),
            ),
        ],
        selected: {selected},
        onSelectionChanged: enabled ? (values) async => await _change(property, values.single) : null,
      );

  /// [context] 的可用屏幕高度，面板最多占 80% 且不超过 720 逻辑像素。
  double mathHeight(BuildContext context) => (MediaQuery.sizeOf(context).height * .8).clamp(0, 720);
}

/// 分割线样式页的完整单行标签；窄屏或大字号超出可用宽度时仅缩小显示，不截断。
/// 不持有状态，选中背景和无障碍选中语义由外层 SegmentedButton 提供。
class _DividerStyleTabLabel extends StatelessWidget {
  /// [label] 是该样式页的完整名称，按当前文字样式显示且不主动放大。
  const _DividerStyleTabLabel(this.label);

  /// 必需的完整页名，不包含图标或额外状态。
  final String label;

  /// 借用 [context] 的文字样式和缩放设置，返回按可用空间缩小的单行标签。
  /// 不修改系统文字缩放或标签语义；该 Widget 无需释放资源。
  @override
  Widget build(BuildContext context) =>
      FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, softWrap: false));
}
