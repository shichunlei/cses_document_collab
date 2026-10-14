import 'dart:async';
import 'dart:convert';

import 'package:cses_document_collab/src/model/collab_resource.dart';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/model/text_delta.dart' as collab;

typedef LocalEditorBlocksChanged =
    void Function(List<CollabEditorBlock> blocks);

const csesUnsupportedBlockType = 'unsupported';
const csesCalloutBlockType = 'callout';
const csesCalloutTargetAttribute = 'cses_callout_target';
const csesCalloutPrefixAttribute = 'cses_callout_prefix';
const csesBlockTextColorAttribute = 'cses_block_text_color';
const csesCodeBlockType = 'code';
const csesLinkBlockType = 'link';
const csesVideoBlockType = 'video';

/// Structural node types reserved for the document header.
///
/// They remain ordinary collaborative blocks instead of page-only Flutter
/// state, which lets title text and cover replacement participate in Yrs
/// updates, offline recovery and cross-device undo-safe transactions.
const csesDocumentCoverBlockType = 'document_cover';
const csesDocumentTitleBlockType = 'document_title';

/// Stable IDs used when an old room is migrated to the fixed header schema.
///
/// Every client derives the same IDs while offline, so two phones opening the
/// same legacy room cannot independently create duplicate cover/title blocks.
const csesDocumentCoverBlockId = 'cses-document-cover';
const csesDocumentTitleBlockId = 'cses-document-title';
const csesDocumentBodyBlockId = 'cses-document-body';

/// Shared node attribute used by the custom link and video renderers.
///
/// The collaborative wire model deliberately reuses `CollabBlock.text` for
/// this value. That keeps URL-backed blocks compatible with the existing Yrs
/// text storage while the AppFlowy document exposes a renderer-friendly
/// attribute instead of an artificial editable Delta.
const csesEmbedUrlAttribute = 'url';
const csesBlockIndentAttribute = 'cses_collab_indent';
const csesSuperscriptAttribute = 'cses_superscript';
const csesBlockBackgroundColorAttribute = 'cses_block_background_color';
const csesBlockBorderColorAttribute = 'cses_block_border_color';
const csesSubscriptAttribute = 'cses_subscript';

/// AppFlowy 内存中的正式列表投影，不直接写入原生 props。
const csesOrderedAttribute = 'cses_blockcraft_ordered';

/// 可撤销的原始编号设置 JSON；与派生编号投影分离，避免撤销时恢复过期 order/ms。
const csesOrderedNumberingAttribute = 'cses_ordered_numbering';

/// 编号历史操作的稳定目标身份；本地元数据，不进入原生 props 或 WS。
const csesOrderedTargetAttribute = 'cses_ordered_target';

/// 在借用的 [state] 中按稳定 [blockId] 设置正式列表编号；[restart] 为 true 时
/// 当前项从 1 开始，否则接续同层级计数器。仅正式编号投影可操作，草稿不发送正式命令。
/// 选择菜单后重新查找节点，删除、类型变化、只读、销毁或已具备请求的设置时返回 false。
/// 成功通过独立 AppFlowy 事务进入撤销历史并返回 true；事务异常交由调用边界处理。
/// 不改变选区、不创建资源；原生持久化和广播由适配器的本地事务订阅负责。
///
/// ```dart
/// import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
/// import 'package:cses_document_collab/src/model/collab_ordered.dart';
/// final adapter = AppFlowyBlockEditorAdapter(
///   initialBlocks: const [CollabEditorBlock(id: 'item', blockType: 'numbered_list',
///     text: '正文', ordered: CollabOrdered(order: 0))],
///   onLocalBlocksChanged: (blocks) { /* 宿主持久化并广播原生增量 */ },
/// );
/// await changeCollabOrderedNumbering(adapter.editorState, 'item', restart: true);
/// adapter.dispose();
/// ```
Future<bool> changeCollabOrderedNumbering(
  EditorState state,
  String blockId, {
  required bool restart,
}) async {
  if (state.isDisposed || !state.editable) return false;
  Node? target;
  for (final node in AppFlowyBlockEditorAdapter._flattenNodes(
    state.document.root.children,
  )) {
    if (node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] ==
        blockId) {
      target = node;
      break;
    }
  }
  if (target == null || target.type != NumberedListBlockKeys.type) return false;
  final raw = target.attributes[csesOrderedAttribute];
  if (raw is! Map) return false;
  final value = CollabOrdered.fromJson(Map<String, dynamic>.from(raw))
      .withNumbering(
        target.attributes[csesOrderedNumberingAttribute] as String? ??
            raw['numbering'] as String? ??
            '{}',
      );
  final settings = jsonDecode(value.numbering) as Map<String, dynamic>;
  if (restart
      ? settings['start'] == 1 && settings['continuePrevious'] == false
      : value.continuesPrevious) {
    return false;
  }
  // 单独封存前一编辑动作，避免编号命令与紧邻的文字输入被一次撤销合并。
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  // AppFlowy updateNode 的自动逆操作会保存未传入的其他节点属性。编号历史必须只保存
  // 两个本地元数据键，防止撤销编号时恢复旧正文、ms 或远端新算出的 order。
  final transaction = state.transaction
    ..add(
      UpdateOperation(
        target.path,
        {
          csesOrderedTargetAttribute: blockId,
          csesOrderedNumberingAttribute: restart
              ? '{"start":1,"continuePrevious":false}'
              : '{"start":0,"continuePrevious":true}',
        },
        {
          csesOrderedTargetAttribute: blockId,
          csesOrderedNumberingAttribute: value.numbering,
        },
      ),
    );
  await state.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

Iterable<Node> _codePropertyNodes(Iterable<Node> nodes) sync* {
  for (final node in nodes) {
    yield node;
    yield* _codePropertyNodes(node.children);
  }
}

/// Changes one code prop without moving the caret or saving unrelated fields in undo.
Future<bool> changeCollabCodeProperty(
  EditorState state,
  String blockId,
  String property,
  Object? value,
) async {
  if (state.isDisposed || !state.editable) return false;
  final attribute = collabCodePropertyAttributes[property];
  if (attribute == null) return false;
  if (property == 'lang' &&
      (value is! String || value.trim().isEmpty || value.length > 80)) {
    return false;
  }
  if (property == 'blockName' &&
      value != null &&
      (value is! String || value.length > 256)) {
    return false;
  }
  if (property == 'collapse' && value != null && value is! bool) return false;
  final node = _codePropertyNodes(state.document.root.children)
      .where(
        (node) =>
            node.type == csesCodeBlockType &&
            node.attributes[AppFlowyBlockEditorAdapter
                    .collabBlockIdAttribute] ==
                blockId,
      )
      .firstOrNull;
  if (node == null) return false;
  final code = CollabCode.fromAttributes(node.attributes);
  final before = code.propertyAttribute(property);
  final after = jsonEncode({'value': value});
  if (before == after) return false;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  final transaction = state.transaction
    ..add(
      UpdateOperation(
        node.path,
        {collabCodeTargetAttribute: blockId, attribute: after},
        {collabCodeTargetAttribute: blockId, attribute: before},
      ),
    );
  await state.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 类型转换待消费的来源身份；Rust 完成替换后清除，不保存为共享属性。
const csesReplacementSourceAttribute = 'cses_replacement_source';

/// Registers the collaborative script attributes with AppFlowy's IME.
///
/// AppFlowy validates collapsed-selection styles before inserting text. Custom
/// attributes must be explicitly registered so newly typed superscript and
/// subscript text follows the same path as its built-in rich-text styles.
void registerCsesRichTextAttributes() {
  for (final attribute in const [
    csesSuperscriptAttribute,
    csesSubscriptAttribute,
  ]) {
    if (!AppFlowyRichTextKeys.supportToggled.contains(attribute)) {
      AppFlowyRichTextKeys.supportToggled.add(attribute);
    }
    if (!AppFlowyRichTextKeys.supportSliced.contains(attribute)) {
      AppFlowyRichTextKeys.supportSliced.add(attribute);
    }
  }
}

final class CollabEditorTextSegment {
  const CollabEditorTextSegment({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.code = false,
    this.textColor,
    this.backgroundColor,
    this.superscript = false,
    this.subscript = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool code;
  final String? textColor;

  /// Inline highlight serialized from AppFlowy's `bg_color` delta attribute.
  ///
  /// The value is an ARGB string such as `0x4dffc107`; keeping the alpha in
  /// the payload makes the same highlight render consistently after a remote
  /// Yrs update is converted back into an AppFlowy document.
  final String? backgroundColor;
  final bool superscript;
  final bool subscript;

  bool get isStyled =>
      bold ||
      italic ||
      underline ||
      strikethrough ||
      code ||
      textColor != null ||
      backgroundColor != null ||
      superscript ||
      subscript;

  Attributes get attributes => {
    if (bold) AppFlowyRichTextKeys.bold: true,
    if (italic) AppFlowyRichTextKeys.italic: true,
    if (underline) AppFlowyRichTextKeys.underline: true,
    if (strikethrough) AppFlowyRichTextKeys.strikethrough: true,
    if (code) AppFlowyRichTextKeys.code: true,
    if (textColor != null) AppFlowyRichTextKeys.textColor: textColor,
    if (backgroundColor != null)
      AppFlowyRichTextKeys.backgroundColor: backgroundColor,
    if (superscript) csesSuperscriptAttribute: true,
    if (subscript) csesSubscriptAttribute: true,
  };

  @override
  int get hashCode => Object.hash(
    text,
    bold,
    italic,
    underline,
    strikethrough,
    code,
    textColor,
    backgroundColor,
    superscript,
    subscript,
  );

  @override
  bool operator ==(Object other) {
    return other is CollabEditorTextSegment &&
        other.text == text &&
        other.bold == bold &&
        other.italic == italic &&
        other.underline == underline &&
        other.strikethrough == strikethrough &&
        other.code == code &&
        other.textColor == textColor &&
        other.backgroundColor == backgroundColor &&
        other.superscript == superscript &&
        other.subscript == subscript;
  }
}

/// Rust 权威块的不可变展示投影，普通正文与图片专属数据分开保存。
///
/// ```dart
/// import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
/// const block = CollabEditorBlock(id: 'p1', blockType: 'paragraph', text: '正文');
/// ```
final class CollabEditorBlock {
  /// 创建块投影。[id] 是稳定块 ID，[blockType] 是手机块类型，[text] 是正文或媒体 URL。
  /// [segments] 是正文格式分段，[checked] 仅适用于 Todo，[alignment] 默认 left，
  /// [indent] 是列表视觉层级 0～6，[image] 仅正式图片使用，null 保持旧草稿行为。
  /// [ordered] 是正式编号只读投影，null 使用草稿编号；[replacesId] 为类型转换来源，
  /// 成功写入后置 null，不能复用为普通新块 ID。
  /// 调用方保持集合不可变；实例不持有编辑器或网络资源。
  const CollabEditorBlock({
    required this.id,
    required this.blockType,
    required this.text,
    this.segments = const [],
    this.checked = false,
    this.alignment = 'left',
    this.indent = 0,
    this.image,
    this.ordered,
    this.code,
    this.resource,
    this.replacesId,
    this.blockBackgroundColor,
    this.blockBorderColor,
    this.parentId,
    this.calloutPrefix,
    this.blockTextColor,
  });

  /// Rust 权威块身份，移动和编辑时保持不变。
  final String id;

  /// AppFlowy 映射所需类型，不等于正式 BlockCraft flavour。
  final String blockType;

  /// 文本块正文，或媒体块资源 URL。
  final String text;

  /// 文本格式投影；图片为空，原题注格式由 Rust 保留。
  final List<CollabEditorTextSegment> segments;

  /// Todo 是否勾选，其他类型为 false。
  final bool checked;

  /// left/center/right/justify/distributed 文字对齐；正式图片写入 props.align。
  final String alignment;

  /// 列表的视觉缩进 0～6，图片为零。
  final int indent;

  /// 正式图片的原始布局和题注；其他块及离线草稿为 null。
  final CollabImage? image;

  /// 正式 ordered 的结构编号，普通块和独立草稿为 null。
  final CollabOrdered? ordered;

  /// Desktop code header metadata, projected without writing shared props.
  final CollabCode? code;
  final CollabResource? resource;

  /// 本地新块所替换的原块身份，普通编辑和远端投影为 null。
  final String? replacesId;

  /// 桌面块外观 CSS 原值，独立于 Delta 的文字高亮。
  final String? blockBackgroundColor;
  final String? blockBorderColor;
  final String? parentId;
  final String? calloutPrefix;
  final String? blockTextColor;

  /// 计算完整投影哈希，图片布局与题注包含在内。
  @override
  int get hashCode => Object.hash(
    id,
    blockType,
    text,
    Object.hashAll(segments),
    checked,
    alignment,
    indent,
    image,
    ordered,
    code,
    resource,
    replacesId,
    blockBackgroundColor,
    blockBorderColor,
    parentId,
    calloutPrefix,
    blockTextColor,
  );

  /// 与 [other] 比较完整投影及待消费替换来源，供本地发布去重和远端刷新使用。
  @override
  bool operator ==(Object other) {
    return other is CollabEditorBlock &&
        other.id == id &&
        other.blockType == blockType &&
        other.text == text &&
        _segmentsEqual(other.segments, segments) &&
        other.checked == checked &&
        other.alignment == alignment &&
        other.indent == indent &&
        other.image == image &&
        other.ordered == ordered &&
        other.code == code &&
        other.resource == resource &&
        other.replacesId == replacesId &&
        other.blockBackgroundColor == blockBackgroundColor &&
        other.blockBorderColor == blockBorderColor &&
        other.parentId == parentId &&
        other.calloutPrefix == calloutPrefix &&
        other.blockTextColor == blockTextColor;
  }

  @override
  String toString() =>
      'CollabEditorBlock($id, $blockType, $text, $segments, $checked, '
      '$alignment, $indent)';
}

/// Maps AppFlowy top-level nodes to the mobile block-level Yrs schema.
///
/// AppFlowy owns rendering, selection, IME and local undo. Rust/Yrs owns block
/// order, block type metadata and native text/props/children. 正式图片的题注保留在
/// image 专属投影中，UI 仍是一个根级资源节点，不把题注混入根顺序。
/// ```dart
/// import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
/// final adapter = AppFlowyBlockEditorAdapter(onLocalBlocksChanged: (blocks) {});
/// // 宿主将 Rust 投影交给 adapter.replaceFromRemote(blocks)。
/// adapter.dispose();
/// ```
final class AppFlowyBlockEditorAdapter {
  /// [onLocalBlocksChanged] 在本地事务完成后接收完整投影；远端回放不调用它。
  /// [initialBlocks] 默认空，由适配器创建可落光标的正文。适配器拥有 EditorState 和事务订阅，
  /// 调用方必须在不再使用编辑器时 dispose，不另行关闭借用的 editorState。
  AppFlowyBlockEditorAdapter({
    required this.onLocalBlocksChanged,
    List<CollabEditorBlock> initialBlocks = const [],
  }) : editorState = _createEditorState(initialBlocks) {
    _lastPublishedBlocks = _readBlocks(editorState, const []);
    _transactionSubscription = editorState.transactionStream.listen(
      _handleTransaction,
    );
  }

  static const collabBlockIdAttribute = 'cses_collab_block_id';

  final LocalEditorBlocksChanged onLocalBlocksChanged;
  final EditorState editorState;

  late final StreamSubscription<EditorTransactionValue>
  _transactionSubscription;
  late List<CollabEditorBlock> _lastPublishedBlocks;
  bool _applyingRemote = false;
  bool _disposed = false;

  /// 当前文档内历史身份到替换身份的链；用于将 AppFlowy Undo/Redo 的旧快照转换为新结构操作。
  /// 普通文本和排序不生成身份。切换文档时清空，避免不同文档的旧撤销快照互相映射。
  final Map<String, String> _replacementIds = {};

  /// 丢弃上一文档的身份链及 Undo/Redo 历史；必须在切换引擎后、回放新文档前调用。
  /// 不关闭编辑器、监听或网络资源，不修改权威文档。
  void resetDocumentHistory() {
    _replacementIds.clear();
    editorState.undoManager.undoStack.clear();
    editorState.undoManager.redoStack.clear();
  }

  List<CollabEditorBlock> get blocks =>
      _readBlocks(editorState, _lastPublishedBlocks);
  String get text => blocks.map((block) => block.text).join('\n');

  /// Applies canonical Rust/Yrs blocks without publishing them as local edits.
  /// [nextBlocks] 是当前权威投影，空列表显示一个 UI 空段落；Future 在事务完成后结束。
  /// 块身份、类型、顺序一致时原位更新文字和媒体属性，保留组件、选区与输入连接；
  /// URL、尺寸和题注复用节点映射，移除的可选投影显式清空。结构不同才重建节点。
  /// 不记录本地撤销或发送 WS；销毁后不执行，事务异常向调用边界传播。
  /// 正式编号及原始设置更新内存投影，不进入历史；成功转换后清除 replacesId。
  Future<void> replaceFromRemote(List<CollabEditorBlock> nextBlocks) async {
    if (_disposed) {
      return;
    }

    final currentBlocks = blocks;
    final targetBlocks = nextBlocks.isEmpty
        ? _emptyDocumentBlocks(currentBlocks)
        : List<CollabEditorBlock>.unmodifiable(nextBlocks);
    if (_blocksEqual(currentBlocks, targetBlocks)) {
      _lastPublishedBlocks = targetBlocks;
      return;
    }

    final currentRootNodes = editorState.document.root.children;
    final currentNodes = _flattenNodes(currentRootNodes).toList();
    // 媒体没有 Delta，但仍可通过属性事务更新。同一结构的原生编号确认必须保留
    // Enter 已创建的节点；整篇删除再插入会让远端路径变换把光标移出文档。
    final canPatchInPlace =
        currentNodes.length == targetBlocks.length &&
        List<bool>.generate(
          currentNodes.length,
          (index) =>
              _nodeBlockId(currentNodes[index]) == targetBlocks[index].id &&
              _nodeBlockType(currentNodes[index]) ==
                  targetBlocks[index].blockType &&
              currentBlocks[index].parentId == targetBlocks[index].parentId &&
              (currentNodes[index].type == csesUnsupportedBlockType ||
                  currentNodes[index].type == csesCalloutBlockType ||
                  currentNodes[index].delta != null ||
                  _isUrlBackedBlock(targetBlocks[index].blockType)),
        ).every((matches) => matches);
    final transaction = editorState.transaction;

    if (canPatchInPlace) {
      for (var index = 0; index < currentNodes.length; index += 1) {
        final node = currentNodes[index];
        final target = targetBlocks[index];
        if (node.type == csesUnsupportedBlockType) continue;
        if (_isUrlBackedBlock(target.blockType)) {
          if (currentBlocks[index] != target) {
            // 统一复用创建节点时的协议映射，避免 URL/布局/题注形成两套编码。
            // updateNode 合并属性，故可选图片投影缺失时需要显式 null 删除旧值。
            transaction.updateNode(node, {
              ..._nodeFromBlock(target).attributes,
              if (target.blockType == ImageBlockKeys.type &&
                  target.image == null)
                collabImageAttribute: null,
            });
          }
          continue;
        }
        final currentSegments = _readNodeSegments(node);
        if (node.type == csesCalloutBlockType) {
          // Container content is represented by its child nodes.
        } else if (!_segmentsEqual(currentSegments, target.segments)) {
          final currentLength = node.delta?.length ?? 0;
          if (currentLength > 0) {
            transaction.deleteText(node, 0, currentLength);
          }
          final targetDelta = _deltaFromBlock(target);
          if (targetDelta.isNotEmpty) {
            transaction.insertTextDelta(node, 0, targetDelta);
          }
        } else {
          final currentText = node.delta?.toPlainText() ?? '';
          final delta = collab.TextDelta.between(currentText, target.text);
          if (delta.deleteLength > 0) {
            transaction.deleteText(node, delta.index, delta.deleteLength);
          }
          if (delta.insertText.isNotEmpty) {
            transaction.insertText(node, delta.index, delta.insertText);
          }
        }
        if (node.type == TodoListBlockKeys.type &&
            node.attributes[TodoListBlockKeys.checked] != target.checked) {
          transaction.updateNode(node, {
            TodoListBlockKeys.checked: target.checked,
          });
        }
        final targetIndent = _supportsIndent(target.blockType)
            ? target.indent
            : 0;
        if (node.attributes[csesCalloutPrefixAttribute] !=
                target.calloutPrefix ||
            node.attributes[csesBlockTextColorAttribute] !=
                target.blockTextColor ||
            node.attributes[csesBlockBackgroundColorAttribute] !=
                target.blockBackgroundColor ||
            node.attributes[csesBlockBorderColorAttribute] !=
                target.blockBorderColor ||
            node.attributes[blockComponentAlign] != target.alignment ||
            node.attributes[csesBlockIndentAttribute] != targetIndent ||
            _readOrdered(node) != target.ordered ||
            _readCode(node) != target.code ||
            node.attributes[csesReplacementSourceAttribute] !=
                target.replacesId) {
          transaction.updateNode(node, {
            csesCalloutPrefixAttribute: target.calloutPrefix,
            csesBlockTextColorAttribute: target.blockTextColor,
            csesBlockBackgroundColorAttribute: target.blockBackgroundColor,
            csesBlockBorderColorAttribute: target.blockBorderColor,
            blockComponentBackgroundColor: parseCollabBlockColor(
              target.blockBackgroundColor,
            )?.toHex(),
            blockComponentAlign: target.alignment,
            csesBlockIndentAttribute: targetIndent,
            csesOrderedAttribute: target.ordered?.toJson(),
            collabCodeAttribute: target.code?.toJson(),
            for (final entry in collabCodePropertyAttributes.entries)
              entry.value: target.code?.propertyAttribute(entry.key),
            csesOrderedNumberingAttribute: target.ordered?.numbering,
            csesOrderedTargetAttribute: target.ordered == null
                ? null
                : target.id,
            csesReplacementSourceAttribute: target.replacesId,
          });
        }
      }
    } else {
      if (currentRootNodes.isNotEmpty) {
        transaction.deleteNodesAtPath([0], currentRootNodes.length);
      }
      transaction.add(
        InsertOperation([0], _nodesFromBlocks(targetBlocks)),
        transform: false,
      );
    }

    if (transaction.operations.isEmpty) {
      _lastPublishedBlocks = targetBlocks;
      return;
    }
    _applyingRemote = true;
    final wasEditable = editorState.editable;
    try {
      // AppFlowy also gates remote transactions on editable. Authoritative
      // replay must still render while the page is in preview/read-only mode.
      editorState.editable = true;
      await editorState.apply(
        transaction,
        isRemote: true,
        options: const ApplyOptions(recordUndo: false, inMemoryUpdate: true),
      );
      _lastPublishedBlocks = targetBlocks;
    } finally {
      editorState.editable = wasEditable;
      _applyingRemote = false;
    }
  }

  /// 在本地 [value] 的 before 阶段按稳定 ID 重定位编号历史，after 阶段发布快照；
  /// 类型转换生成新身份并记录来源供 Rust 保留扩展数据。
  /// 远端回放及销毁后不发布；Undo/Redo 的历史身份经文档内映射恢复为当前可替换来源。
  /// 仅明确修改编号设置属性的 UpdateOperation 生成编号写入意图；普通文字/结构快照
  /// 即使携带旧设置也不会覆盖原生 start/continuePrevious。撤销和重做复用相同路径。
  void _handleTransaction(EditorTransactionValue value) {
    if (_disposed || _applyingRemote) {
      return;
    }
    if (value.$1 == TransactionTime.before) {
      _resolveNumberingTargets(value.$2);
      _protectUnsupportedBlocks(value.$2);
      return;
    }
    final numberingNodes = <Node>{};
    final codeEdits = <Node, Set<String>>{};
    final resourceEdits = <Node, Set<String>>{};
    for (final operation in value.$2.operations.whereType<UpdateOperation>()) {
      final node = editorState.getNodeAtPath(operation.path);
      if (node != null && isCollabResourceType(node.type)) {
        if (operation.attributes.containsKey(csesEmbedUrlAttribute)) {
          resourceEdits.putIfAbsent(node, () => {}).add('url');
        }
        for (final key in collabResourceKeys) {
          if (operation.attributes.containsKey(
            resourcePropertyAttribute(key),
          )) {
            resourceEdits.putIfAbsent(node, () => {}).add(key);
          }
        }
      }
      if (node != null && node.type == csesCodeBlockType) {
        for (final entry in collabCodePropertyAttributes.entries) {
          if (operation.attributes.containsKey(entry.value)) {
            codeEdits.putIfAbsent(node, () => {}).add(entry.key);
          }
        }
      }
      if (operation.attributes.containsKey(csesOrderedNumberingAttribute)) {
        final node = editorState.getNodeAtPath(operation.path);
        if (node != null) numberingNodes.add(node);
      }
    }
    final nextBlocks = _readBlocks(
      editorState,
      _lastPublishedBlocks,
      numberingNodes: numberingNodes,
      codeEdits: codeEdits,
      resourceEdits: resourceEdits,
    );
    if (_blocksEqual(nextBlocks, _lastPublishedBlocks)) {
      return;
    }
    _lastPublishedBlocks = List<CollabEditorBlock>.unmodifiable(nextBlocks);
    onLocalBlocksChanged(_lastPublishedBlocks);
  }

  /// Follow paths through structural operations so range deletion/conversion cannot
  /// remove a placeholder or its parent. Reject the whole action before history/input.
  void _protectUnsupportedBlocks(Transaction transaction) {
    final paths = _flattenNodes(editorState.document.root.children)
        .where((node) => node.type == csesUnsupportedBlockType)
        .map((node) => List<int>.from(node.path))
        .toList();
    bool containsPlaceholder(Node node) =>
        node.type == csesUnsupportedBlockType ||
        node.children.any(containsPlaceholder);
    bool prefix(Path a, Path b) =>
        a.length <= b.length &&
        List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
    var blocked = false;
    for (final operation in transaction.operations) {
      final path = operation.path;
      if (operation is InsertOperation) {
        blocked =
            operation.nodes.any(containsPlaceholder) ||
            paths.any((p) => p.length < path.length && prefix(p, path));
      } else if (operation is DeleteOperation && path.isNotEmpty) {
        blocked = paths.any(
          (p) =>
              p.length >= path.length &&
              prefix(path.parent, p) &&
              p[path.length - 1] >= path.last &&
              p[path.length - 1] < path.last + operation.nodes.length,
        );
      } else {
        blocked = paths.any((p) => prefix(p, path));
      }
      if (blocked) break;
      if (path.isNotEmpty &&
          (operation is InsertOperation || operation is DeleteOperation)) {
        final count = operation is InsertOperation
            ? operation.nodes.length
            : -(operation as DeleteOperation).nodes.length;
        for (final p in paths) {
          if (p.length >= path.length &&
              prefix(path.parent, p) &&
              p[path.length - 1] >= path.last) {
            p[path.length - 1] += count;
          }
        }
      }
    }
    if (blocked) {
      transaction.operations = [];
      transaction.afterSelection = transaction.beforeSelection;
    }
  }

  /// 在借用的 [transaction] 应用前重定位明确编号操作；AppFlowy 的历史路径可能因远端
  /// 重排失效，因此只使用操作内保存的稳定目标 ID。删除或已转为其他类型时丢弃该操作。
  /// 其他操作保持原状；同步事务 before 通知保证修改发生在节点写入及历史记录之前。
  /// 不创建新事务或资源，也不直接改动原生文档，撤销/重做记录最终实际应用的路径。
  void _resolveNumberingTargets(Transaction transaction) {
    final codePropertiesOnly =
        transaction.operations.isNotEmpty &&
        transaction.operations.every(
          (operation) =>
              operation is UpdateOperation &&
              (operation.attributes.containsKey(collabCodeTargetAttribute) ||
                  operation.attributes.containsKey(
                    collabResourceTargetAttribute,
                  )),
        );
    if (codePropertiesOnly) {
      // Header undo should preserve the current caret, including after reorder/deletion.
      transaction.beforeSelection = editorState.selection;
      transaction.afterSelection = editorState.selection;
    }
    final operations = <Operation>[];
    for (final operation in transaction.operations) {
      if (operation is! UpdateOperation) {
        operations.add(operation);
        continue;
      }
      if (operation.attributes.containsKey(collabResourceTargetAttribute)) {
        if (!editorState.editable) continue;
        final id = operation.attributes[collabResourceTargetAttribute];
        final kind = operation.attributes[collabResourceKindAttribute];
        final node = _flattenNodes(
          editorState.document.root.children,
        ).where((n) => _nodeBlockId(n) == id && n.type == kind).firstOrNull;
        if (node != null) operations.add(operation.copyWith(path: node.path));
        continue;
      }
      final isCallout = operation.attributes.containsKey(
        csesCalloutTargetAttribute,
      );
      final isCode = operation.attributes.containsKey(
        collabCodeTargetAttribute,
      );
      final isOrdered = operation.attributes.containsKey(
        csesOrderedNumberingAttribute,
      );
      if (!isCallout && !isCode && !isOrdered) {
        operations.add(operation);
        continue;
      }
      if ((isCallout || isCode) && !editorState.editable) continue;
      final targetKey = isCallout
          ? csesCalloutTargetAttribute
          : isCode
          ? collabCodeTargetAttribute
          : csesOrderedTargetAttribute;
      final type = isCallout
          ? csesCalloutBlockType
          : isCode
          ? csesCodeBlockType
          : NumberedListBlockKeys.type;
      var id = operation.attributes[targetKey] as String?;
      if (id == null) continue;
      while (_replacementIds.containsKey(id)) {
        id = _replacementIds[id];
      }
      final node = _flattenNodes(
        editorState.document.root.children,
      ).where((n) => _nodeBlockId(n) == id && n.type == type).firstOrNull;
      if (node != null) operations.add(operation.copyWith(path: node.path));
    }
    transaction.operations = operations;
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_transactionSubscription.cancel());
    editorState.dispose();
  }

  static EditorState _createEditorState(List<CollabEditorBlock> blocks) {
    final nodes = blocks.isEmpty
        ? [_newEmptyParagraphNode()]
        : _nodesFromBlocks(blocks);
    return EditorState(
      document: Document(
        root: Node(type: 'page', id: 'cses-demo-page', children: nodes),
      ),
    );
  }

  static List<CollabEditorBlock> _emptyDocumentBlocks(
    List<CollabEditorBlock> current,
  ) {
    if (current.length == 1 &&
        current.first.blockType == ParagraphBlockKeys.type &&
        current.first.text.isEmpty) {
      return List<CollabEditorBlock>.unmodifiable(current);
    }
    final node = _newEmptyParagraphNode();
    return [
      CollabEditorBlock(
        id: _nodeBlockId(node),
        blockType: ParagraphBlockKeys.type,
        text: '',
        segments: const [],
        checked: false,
        alignment: 'left',
        indent: 0,
      ),
    ];
  }

  static Node _newEmptyParagraphNode() {
    final node = Node(
      type: ParagraphBlockKeys.type,
      attributes: {ParagraphBlockKeys.delta: (Delta()..insert('')).toJson()},
    );
    node.updateAttributes({collabBlockIdAttribute: node.id});
    return node;
  }

  static Iterable<Node> _flattenNodes(Iterable<Node> nodes) sync* {
    for (final node in nodes) {
      yield node;
      if (node.type == csesCalloutBlockType) {
        yield* _flattenNodes(node.children);
      }
    }
  }

  static List<Node> _nodesFromBlocks(List<CollabEditorBlock> blocks) {
    final nodes = {for (final block in blocks) block.id: _nodeFromBlock(block)};
    final roots = <Node>[];
    for (final block in blocks) {
      final node = nodes[block.id]!;
      final parent = nodes[block.parentId];
      if (parent != null && parent.type == csesCalloutBlockType) {
        parent.insert(node);
      } else {
        roots.add(node);
      }
    }
    return roots;
  }

  /// 将权威 [block] 转为 AppFlowy 节点，图片保存强类型专属数据的 Map 投影。
  /// 题注留在资源属性而非 AppFlowy children；实际父子关系由 Rust 的共享类型持有。
  static Node _nodeFromBlock(CollabEditorBlock block) {
    if (block.blockType == csesUnsupportedBlockType) {
      return Node(
        type: csesUnsupportedBlockType,
        id: block.id,
        attributes: {collabBlockIdAttribute: block.id},
      );
    }
    if (block.blockType == csesCalloutBlockType) {
      return Node(
        type: csesCalloutBlockType,
        id: block.id,
        attributes: {
          collabBlockIdAttribute: block.id,
          csesCalloutTargetAttribute: block.id,
          csesCalloutPrefixAttribute: block.calloutPrefix,
          csesBlockTextColorAttribute: block.blockTextColor,
          csesBlockBackgroundColorAttribute: block.blockBackgroundColor,
          csesBlockBorderColorAttribute: block.blockBorderColor,
        },
      );
    }
    if (_isUrlBackedBlock(block.blockType)) {
      final isImage = block.blockType == ImageBlockKeys.type;
      return Node(
        type: block.blockType,
        id: block.id,
        attributes: {
          // AppFlowy's image component and the custom embed components both
          // currently use `url`; spelling out the key choice documents which
          // renderer owns the attribute and avoids coupling future formats.
          if (isCollabResourceType(block.blockType))
            ...(block.resource ?? const CollabResource()).nodeAttributes,
          if (isImage) ImageBlockKeys.url: block.text,
          if (!isImage) csesEmbedUrlAttribute: block.text,
          if (isImage) ImageBlockKeys.align: block.alignment,
          if (isImage && block.image != null)
            collabImageAttribute: block.image!.toJson(),
          collabBlockIdAttribute: block.id,
          csesBlockBackgroundColorAttribute: block.blockBackgroundColor,
          csesBlockBorderColorAttribute: block.blockBorderColor,
          blockComponentBackgroundColor: parseCollabBlockColor(
            block.blockBackgroundColor,
          )?.toHex(),
          blockComponentAlign: block.alignment,
          csesBlockIndentAttribute: 0,
        },
      );
    }

    final (nodeType, deltaKey, extraAttributes) = switch (block.blockType) {
      final type when type.startsWith('heading_') => (
        HeadingBlockKeys.type,
        HeadingBlockKeys.delta,
        <String, Object>{
          HeadingBlockKeys.level:
              int.tryParse(type.substring('heading_'.length))?.clamp(1, 9) ?? 1,
        },
      ),
      BulletedListBlockKeys.type => (
        BulletedListBlockKeys.type,
        BulletedListBlockKeys.delta,
        <String, Object>{},
      ),
      NumberedListBlockKeys.type => (
        NumberedListBlockKeys.type,
        NumberedListBlockKeys.delta,
        <String, Object>{},
      ),
      TodoListBlockKeys.type => (
        TodoListBlockKeys.type,
        TodoListBlockKeys.delta,
        <String, Object>{TodoListBlockKeys.checked: block.checked},
      ),
      QuoteBlockKeys.type => (
        QuoteBlockKeys.type,
        QuoteBlockKeys.delta,
        <String, Object>{},
      ),
      csesCodeBlockType => (
        csesCodeBlockType,
        blockComponentDelta,
        <String, Object>{},
      ),
      csesDocumentTitleBlockType => (
        csesDocumentTitleBlockType,
        blockComponentDelta,
        <String, Object>{},
      ),
      _ => (
        ParagraphBlockKeys.type,
        ParagraphBlockKeys.delta,
        <String, Object>{},
      ),
    };
    return Node(
      type: nodeType,
      id: block.id,
      attributes: {
        deltaKey: _deltaFromBlock(block).toJson(),
        collabBlockIdAttribute: block.id,
        if (block.code != null) collabCodeAttribute: block.code!.toJson(),
        if (block.code != null) ...block.code!.nodeAttributes,
        if (block.ordered != null)
          csesOrderedAttribute: block.ordered!.toJson(),
        if (block.ordered != null)
          csesOrderedNumberingAttribute: block.ordered!.numbering,
        if (block.ordered != null) csesOrderedTargetAttribute: block.id,
        if (block.replacesId != null)
          csesReplacementSourceAttribute: block.replacesId,
        csesBlockBackgroundColorAttribute: block.blockBackgroundColor,
        csesBlockBorderColorAttribute: block.blockBorderColor,
        blockComponentBackgroundColor: parseCollabBlockColor(
          block.blockBackgroundColor,
        )?.toHex(),
        blockComponentAlign: block.alignment,
        csesBlockIndentAttribute: _supportsIndent(block.blockType)
            ? block.indent
            : 0,
        ...extraAttributes,
      },
    );
  }

  /// 从借用 [state] 读取完整根投影，[previous] 用于恢复身份及识别 flavour 转换。
  /// 图片属性显式恢复为强类型；远端回放期间的发布抑制由调用方负责。
  /// 转换生成新的协同身份，历史身份链保证 Undo/Redo 仍替换当前块，保留 Rust 原生扩展属性。
  /// [numberingNodes] 默认空集合，只有当前本地事务明确修改编号设置的节点才生成写入意图。
  /// 恢复为有序列表的历史节点保留其编号投影，Rust 仅在新身份替换时用它初始化原始设置；
  /// 正常新转入有序列表的节点由类型命令移除旧投影，走默认续号。非有序目标清理内存编号数据。
  List<CollabEditorBlock> _readBlocks(
    EditorState state,
    List<CollabEditorBlock> previous, {
    Set<Node> numberingNodes = const {},
    Map<Node, Set<String>> codeEdits = const {},
    Map<Node, Set<String>> resourceEdits = const {},
  }) {
    final nodes = _flattenNodes(state.document.root.children).toList();
    final explicitIds = nodes
        .map((node) => node.attributes[collabBlockIdAttribute])
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    final seenIds = <String>{};
    final previousById = {for (final block in previous) block.id: block};
    return List<CollabEditorBlock>.generate(nodes.length, (index) {
      final node = nodes[index];
      var blockId = _nodeBlockId(node);
      while (!previousById.containsKey(blockId) &&
          _replacementIds.containsKey(blockId)) {
        blockId = _replacementIds[blockId]!;
      }
      final attributeValue = node.attributes[collabBlockIdAttribute];
      final hasExplicitId =
          attributeValue is String && attributeValue.isNotEmpty;
      if (!hasExplicitId || blockId.isEmpty || seenIds.contains(blockId)) {
        final previousId = index < previous.length ? previous[index].id : null;
        blockId =
            previousId != null &&
                !explicitIds.contains(previousId) &&
                !seenIds.contains(previousId)
            ? previousId
            : node.id;
      }
      final before = previousById[blockId];
      if (!_applyingRemote &&
          before != null &&
          _formalFlavour(before.blockType) !=
              _formalFlavour(_nodeBlockType(node))) {
        final source = blockId;
        blockId = Node(type: ParagraphBlockKeys.type).id;
        _replacementIds[source] = blockId;
        node.updateAttributes({
          csesReplacementSourceAttribute: source,
          if (node.type != NumberedListBlockKeys.type) ...{
            csesOrderedAttribute: null,
            csesOrderedNumberingAttribute: null,
            csesOrderedTargetAttribute: null,
          },
          if (node.type == NumberedListBlockKeys.type)
            csesOrderedTargetAttribute: blockId,
        });
      }
      seenIds.add(blockId);
      if (attributeValue != blockId) {
        node.updateAttributes({collabBlockIdAttribute: blockId});
      }
      return CollabEditorBlock(
        id: blockId,
        parentId: node.parent?.type == csesCalloutBlockType
            ? _nodeBlockId(node.parent!)
            : null,
        calloutPrefix: node.type == csesCalloutBlockType
            ? node.attributes[csesCalloutPrefixAttribute] as String?
            : null,
        blockTextColor: node.type == csesCalloutBlockType
            ? node.attributes[csesBlockTextColorAttribute] as String?
            : null,
        resource: isCollabResourceType(node.type)
            ? CollabResource.fromAttributes(
                node.attributes,
                edited: resourceEdits[node] ?? const {},
              )
            : null,
        code: _readCode(node, editedProperties: codeEdits[node] ?? const {}),
        blockType: _nodeBlockType(node),
        text: _readNodePlainText(node),
        ordered: node.type == NumberedListBlockKeys.type
            ? _readOrdered(node, edited: numberingNodes.contains(node))
            : null,
        replacesId: node.attributes[csesReplacementSourceAttribute] as String?,
        image:
            node.type == ImageBlockKeys.type &&
                node.attributes[collabImageAttribute] is Map
            ? CollabImage.fromJson(
                Map<String, dynamic>.from(
                  node.attributes[collabImageAttribute] as Map,
                ),
              )
            : null,
        segments: _readNodeSegments(node),
        checked:
            node.type == TodoListBlockKeys.type &&
            (node.attributes[TodoListBlockKeys.checked] as bool? ?? false),
        blockBackgroundColor:
            node.attributes[csesBlockBackgroundColorAttribute] as String?,
        blockBorderColor:
            node.attributes[csesBlockBorderColorAttribute] as String?,
        alignment: _nodeAlignment(node),
        indent: _supportsIndent(_nodeBlockType(node))
            ? (node.attributes[csesBlockIndentAttribute] as int? ?? 0).clamp(
                0,
                6,
              )
            : 0,
      );
    }, growable: false);
  }

  /// 从借用 [node] 恢复正式编号及设置；草稿或未投影的新项返回 null。
  /// [edited] 默认 false，仅本地设置事务指定节点时为 true，生成一次性写入意图。
  /// 不修改节点或写原生文档；缺失设置属性回退原投影，支持历史节点恢复。
  static CollabOrdered? _readOrdered(Node node, {bool edited = false}) {
    final value = node.attributes[csesOrderedAttribute];
    if (value is! Map) return null;
    final ordered = CollabOrdered.fromJson(Map<String, dynamic>.from(value));
    return ordered.withNumbering(
      node.attributes[csesOrderedNumberingAttribute] as String? ??
          ordered.numbering,
      edited: edited,
    );
  }

  static CollabCode? _readCode(
    Node node, {
    Set<String> editedProperties = const {},
  }) {
    final value = node.attributes[collabCodeAttribute];
    return node.type == csesCodeBlockType &&
            (value is Map ||
                collabCodePropertyAttributes.values.any(
                  node.attributes.containsKey,
                ))
        ? CollabCode.fromAttributes(
            node.attributes,
            editedProperties: editedProperties,
          )
        : null;
  }

  /// 将手机 [type] 归到正式 flavour；标题级别变化仍是同一 paragraph，不替换身份。
  static String _formalFlavour(String type) =>
      type.startsWith('heading_') ? 'paragraph' : type;

  static String _nodeBlockId(Node node) {
    final value = node.attributes[collabBlockIdAttribute];
    return value is String && value.isNotEmpty ? value : node.id;
  }

  static String _nodeBlockType(Node node) {
    if (isCollabResourceType(node.type)) return node.type;
    if (node.type == csesUnsupportedBlockType) return csesUnsupportedBlockType;
    if (node.type == csesCalloutBlockType) return csesCalloutBlockType;
    return switch (node.type) {
      HeadingBlockKeys.type =>
        'heading_${(node.attributes[HeadingBlockKeys.level] as int? ?? 1).clamp(1, 9)}',
      BulletedListBlockKeys.type => BulletedListBlockKeys.type,
      NumberedListBlockKeys.type => NumberedListBlockKeys.type,
      TodoListBlockKeys.type => TodoListBlockKeys.type,
      QuoteBlockKeys.type => QuoteBlockKeys.type,
      csesCodeBlockType => csesCodeBlockType,
      ImageBlockKeys.type => ImageBlockKeys.type,
      csesLinkBlockType => csesLinkBlockType,
      csesVideoBlockType => csesVideoBlockType,
      csesDocumentCoverBlockType => csesDocumentCoverBlockType,
      csesDocumentTitleBlockType => csesDocumentTitleBlockType,
      _ => ParagraphBlockKeys.type,
    };
  }

  static Delta _deltaFromBlock(CollabEditorBlock block) {
    final delta = Delta();
    if (block.segments.isEmpty) {
      delta.insert(block.text);
      return delta;
    }
    for (final segment in block.segments) {
      delta.insert(segment.text, attributes: segment.attributes);
    }
    return delta;
  }

  static List<CollabEditorTextSegment> _readNodeSegments(Node node) {
    final delta = node.delta;
    if (delta == null) {
      return const [];
    }
    final segments = delta
        .whereType<TextInsert>()
        .map((operation) {
          final attributes = operation.attributes ?? const <String, Object>{};
          return CollabEditorTextSegment(
            text: operation.text,
            bold: attributes[AppFlowyRichTextKeys.bold] == true,
            italic: attributes[AppFlowyRichTextKeys.italic] == true,
            underline: attributes[AppFlowyRichTextKeys.underline] == true,
            strikethrough:
                attributes[AppFlowyRichTextKeys.strikethrough] == true,
            code: attributes[AppFlowyRichTextKeys.code] == true,
            textColor: attributes[AppFlowyRichTextKeys.textColor] is String
                ? attributes[AppFlowyRichTextKeys.textColor] as String
                : null,
            backgroundColor:
                attributes[AppFlowyRichTextKeys.backgroundColor] is String
                ? attributes[AppFlowyRichTextKeys.backgroundColor] as String
                : null,
            superscript: attributes[csesSuperscriptAttribute] == true,
            subscript: attributes[csesSubscriptAttribute] == true,
          );
        })
        .toList(growable: false);
    return segments.any((segment) => segment.isStyled) ? segments : const [];
  }

  static String _nodeAlignment(Node node) {
    final value = node.attributes[blockComponentAlign];
    return const {
          'left',
          'center',
          'right',
          'justify',
          'distributed',
        }.contains(value)
        ? value as String
        : 'left';
  }

  static bool _supportsIndent(String blockType) =>
      blockType == BulletedListBlockKeys.type ||
      blockType == NumberedListBlockKeys.type ||
      blockType == TodoListBlockKeys.type;

  static String _readNodePlainText(Node node) {
    if (node.type == csesCalloutBlockType) return "";
    // Media/embed nodes intentionally have no Delta. Their URL is serialized
    // through `CollabBlock.text` so Rust/Yrs can preserve and synchronize it
    // with the same mature per-block Y.Text mechanism as ordinary content.
    if (node.type == ImageBlockKeys.type) {
      return node.attributes[ImageBlockKeys.url] as String? ?? '';
    }
    if (isCollabResourceType(node.type) ||
        node.type == csesLinkBlockType ||
        node.type == csesVideoBlockType ||
        node.type == csesDocumentCoverBlockType) {
      return node.attributes[csesEmbedUrlAttribute] as String? ?? '';
    }
    final delta = node.delta;
    if (delta != null) {
      return delta.toPlainText();
    }
    return node.children.map(_readNodePlainText).join('\n');
  }

  static bool _blocksEqual(
    List<CollabEditorBlock> left,
    List<CollabEditorBlock> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}

bool _isUrlBackedBlock(String blockType) =>
    isCollabResourceType(blockType) ||
    blockType == ImageBlockKeys.type ||
    blockType == csesLinkBlockType ||
    blockType == csesVideoBlockType ||
    blockType == csesDocumentCoverBlockType;

bool _segmentsEqual(
  List<CollabEditorTextSegment> left,
  List<CollabEditorTextSegment> right,
) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
