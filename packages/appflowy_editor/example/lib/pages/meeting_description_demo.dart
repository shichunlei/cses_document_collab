import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor_plugins/appflowy_editor_plugins.dart';
import 'package:example/meeting/meeting_block_builder.dart';
import 'package:example/meeting/meeting_block_form.dart';
import 'package:example/meeting/meeting_document_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Demonstrates editing a CSES meeting description in AppFlowy Editor.
///
/// The bundled sample is imported as a document tree. The actions above the
/// editor export the live tree in the server's original JSON shape.
class MeetingDescriptionDemo extends StatefulWidget {
  /// Creates the self-contained meeting description demo page.
  const MeetingDescriptionDemo({super.key});

  @override
  State<MeetingDescriptionDemo> createState() => _MeetingDescriptionDemoState();
}

/// Owns the editor state and reloads the local meeting sample on demand.
class _MeetingDescriptionDemoState extends State<MeetingDescriptionDemo> {
  static const _blockKinds = <(String, String)>[
    ('paragraph', '段落'),
    ('heading', '标题'),
    ('ordered', '有序列表'),
    ('bullet', '无序列表'),
    ('todo', '待办'),
    ('blockquote', '引用'),
    ('code', '代码'),
    ('divider', '分割线'),
    ('image', '图片'),
    ('callout', '高亮块'),
    ('figma-embed', 'Figma 嵌入'),
    ('juejin-embed', '掘金嵌入'),
    ('audio', '音频'),
    ('video', '视频'),
    ('bookmark', '网页书签'),
    ('attachment', '附件'),
  ];
  static const _blocksWithProps = <String>{
    'divider',
    'image',
    'callout',
    'figma-embed',
    'juejin-embed',
    'audio',
    'video',
    'bookmark',
    'attachment',
  };
  final MeetingDocumentAdapter _adapter = const MeetingDocumentAdapter();
  EditorState? _editorState;
  EditorScrollController? _scrollController;
  Object? _loadError;
  bool _loading = true;

  /// Starts loading the bundled sample after the widget is initialized.
  @override
  void initState() {
    super.initState();
    unawaited(_loadSample());
  }

  /// Releases the editor's document, streams, and selection resources.
  @override
  void dispose() {
    _scrollController?.dispose();
    _editorState?.dispose();
    super.dispose();
  }

  /// Loads the exact meeting protocol fixture and swaps its editor state.
  ///
  /// A retired state is disposed after its previous widget tree has unmounted.
  Future<void> _loadSample() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final content = await rootBundle.loadString(
        'assets/meeting/docDescription.json',
      );
      final source = Map<String, dynamic>.from(jsonDecode(content) as Map);
      final next = EditorState(document: _adapter.import(source));
      final nextScroll = EditorScrollController(
        editorState: next,
        shrinkWrap: false,
      );
      if (!mounted) {
        nextScroll.dispose();
        next.dispose();
        return;
      }
      final previous = _editorState;
      final previousScroll = _scrollController;
      setState(() {
        _editorState = next;
        _scrollController = nextScroll;
        _loading = false;
      });
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          previousScroll?.dispose();
          previous.dispose();
        });
      }
    } catch (error, stackTrace) {
      debugPrint('Meeting demo fixture failed: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _loadError = error;
          _loading = false;
        });
      }
    }
  }

  /// Copies the current meeting protocol tree to the system clipboard.
  Future<void> _copyJson() async {
    final state = _editorState;
    if (state == null) return;
    final output = const JsonEncoder.withIndent(
      '  ',
    ).convert(_adapter.export(state.document));
    await Clipboard.setData(ClipboardData(text: output));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('会议描述 JSON 已复制')));
    }
  }

  /// Shows the current server-format JSON without replacing the editor state.
  Future<void> _showJson() async {
    final state = _editorState;
    if (state == null) return;
    final output = const JsonEncoder.withIndent(
      '  ',
    ).convert(_adapter.export(state.document));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('会议描述 JSON'),
        content: SizedBox(
          width: 760,
          height: 560,
          child: SingleChildScrollView(child: SelectableText(output)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// Inserts a selected block after the current top-level editor selection.
  ///
  /// Meeting-only blocks collect their protocol properties first. A canceled
  /// form leaves the document untouched; the editor transaction supports undo.
  Future<void> _addBlock() async {
    final state = _editorState;
    if (state == null) return;
    final selectedPath = state.selection?.start.path;
    final flavour = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.7,
          child: ListView.builder(
            itemCount: _blockKinds.length,
            itemBuilder: (context, index) {
              final (value, label) = _blockKinds[index];
              return ListTile(
                title: Text(label),
                onTap: () => Navigator.pop(sheetContext, value),
              );
            },
          ),
        ),
      ),
    );
    if (!mounted || _editorState != state || flavour == null) return;
    Map<String, dynamic> props = {};
    if (_blocksWithProps.contains(flavour)) {
      final result = await showMeetingBlockForm(context, flavour: flavour);
      if (!mounted || _editorState != state || result == null) return;
      props = result;
    }
    final insertIndex = selectedPath == null || selectedPath.isEmpty
        ? state.document.root.children.length
        : (selectedPath.first + 1).clamp(
            0,
            state.document.root.children.length,
          );
    final node = _adapter.createBlock(flavour, props: props);
    final transaction = state.transaction
      ..insertNode([insertIndex], node, deepCopy: false);
    await _applyTransaction(state, transaction);
  }

  /// Opens the property form and applies changes to [node] through undo history.
  Future<void> _editBlock(Node node) async {
    final state = _editorState;
    if (state == null || node.parent == null) return;
    final source = node.attributes['_csesMeetingSource'];
    if (source is! Map || source['flavour'] is! String) return;
    final props = await showMeetingBlockForm(
      context,
      flavour: source['flavour'] as String,
      initialProps: _adapter.propsOf(node),
    );
    if (!mounted ||
        _editorState != state ||
        node.parent == null ||
        props == null) {
      return;
    }
    final transaction = state.transaction
      ..updateNode(node, _adapter.updatedBlockAttributes(node, props));
    await _applyTransaction(state, transaction);
  }

  /// Removes [node] as one undoable editor operation.
  Future<void> _deleteBlock(Node node) async {
    final state = _editorState;
    if (state == null || node.parent == null) return;
    final transaction = state.transaction..deleteNode(node);
    await _applyTransaction(state, transaction);
  }

  /// Applies [transaction] to [state] and reports unexpected editor failures.
  Future<void> _applyTransaction(
    EditorState state,
    Transaction transaction,
  ) async {
    try {
      await state.apply(transaction);
    } catch (error, stackTrace) {
      debugPrint('Meeting demo edit failed: $error\n$stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('编辑失败，请重试')));
      }
    }
  }

  /// Builds the editor, export controls, or a sample-loading error.
  @override
  Widget build(BuildContext context) {
    final state = _editorState;
    return Scaffold(
      appBar: AppBar(title: const Text('会议描述 · AppFlowy Demo')),
      body: _loading && state == null
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null && state == null
          ? Center(child: Text('样例加载失败：$_loadError'))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: state == null ? null : _copyJson,
                        icon: const Icon(Icons.copy),
                        label: const Text('复制服务端 JSON'),
                      ),
                      OutlinedButton.icon(
                        onPressed: state == null ? null : _showJson,
                        icon: const Icon(Icons.data_object),
                        label: const Text('查看 JSON'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loading ? null : _loadSample,
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('重载样例'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: state == null ? null : _addBlock,
                        icon: const Icon(Icons.add),
                        label: const Text('添加块'),
                      ),
                      const Text('点击块上的编辑图标可修改属性'),
                    ],
                  ),
                ),
                if (_loading) const LinearProgressIndicator(),
                Expanded(
                  child: state == null
                      ? const SizedBox.shrink()
                      : _buildEditor(state),
                ),
              ],
            ),
    );
  }

  /// Uses standard text components and meeting-specific media components.
  Widget _buildEditor(EditorState state) {
    final custom = MeetingBlockBuilder(
      onEdit: (node) => unawaited(_editBlock(node)),
      onDelete: (node) => unawaited(_deleteBlock(node)),
    );
    final builders = <String, BlockComponentBuilder>{
      ...standardBlockComponentBuilderMap,
      CodeBlockKeys.type: CodeBlockComponentBuilder(),
      'image': custom,
      'divider': custom,
      'cses_callout': custom,
      'cses_figma_embed': custom,
      'cses_juejin_embed': custom,
      'cses_audio': custom,
      'cses_video': custom,
      'cses_bookmark': custom,
      'cses_attachment': custom,
    };
    final editor = AppFlowyEditor(
      editorState: state,
      editable: true,
      editorScrollController: _scrollController,
      blockComponentBuilders: builders,
      editorStyle:
          defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS
          ? const EditorStyle.mobile(padding: EdgeInsets.all(16))
          : const EditorStyle.desktop(padding: EdgeInsets.all(24)),
    );
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return MobileToolbarV2(
        editorState: state,
        toolbarHeight: 48,
        toolbarItems: [
          textDecorationMobileToolbarItemV2,
          buildTextAndBackgroundColorMobileToolbarItem(),
          blocksMobileToolbarItem,
          linkMobileToolbarItem,
          dividerMobileToolbarItem,
        ],
        child: editor,
      );
    }
    return FloatingToolbar(
      editorState: state,
      editorScrollController: _scrollController!,
      textDirection: TextDirection.ltr,
      items: [
        paragraphItem,
        ...headingItems,
        ...markdownFormatItems,
        quoteItem,
        bulletedListItem,
        numberedListItem,
        linkItem,
        ...alignmentItems,
      ],
      child: editor,
    );
  }
}
