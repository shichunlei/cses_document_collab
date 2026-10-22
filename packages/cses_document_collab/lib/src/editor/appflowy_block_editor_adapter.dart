import 'dart:async';
import 'dart:convert';

import 'package:cses_document_collab/src/editor/editor_text_attributes.dart';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_kr.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_page_divider.dart';
import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_link_view.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:cses_document_collab/src/model/collab_mermaid.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:cses_document_collab/src/model/collab_task_card.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/model/text_delta.dart' as collab;

typedef LocalEditorBlocksChanged = void Function(List<CollabEditorBlock> blocks);

const csesUnsupportedBlockType = 'unsupported';
const csesCalloutBlockType = 'callout';
const csesCalloutTargetAttribute = 'cses_callout_target';
const csesCalloutPrefixAttribute = 'cses_callout_prefix';
const csesBlockTextColorAttribute = 'cses_block_text_color';
const csesCodeBlockType = 'code';
const csesLinkBlockType = 'link';
const csesVideoBlockType = 'video';

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
Future<bool> changeCollabOrderedNumbering(EditorState state, String blockId, {required bool restart}) async {
  if (state.isDisposed || !state.editable) return false;
  Node? target;
  for (final node in AppFlowyBlockEditorAdapter._flattenNodes(state.document.root.children)) {
    if (node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] == blockId) {
      target = node;
      break;
    }
  }
  if (target == null || target.type != NumberedListBlockKeys.type) return false;
  final raw = target.attributes[csesOrderedAttribute];
  if (raw is! Map) return false;
  final value = CollabOrdered.fromJson(
    Map<String, dynamic>.from(raw),
  ).withNumbering(target.attributes[csesOrderedNumberingAttribute] as String? ?? raw['numbering'] as String? ?? '{}');
  final settings = jsonDecode(value.numbering) as Map<String, dynamic>;
  if (restart ? settings['start'] == 1 && settings['continuePrevious'] == false : value.continuesPrevious) {
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
        {csesOrderedTargetAttribute: blockId, csesOrderedNumberingAttribute: value.numbering},
      ),
    );
  await state.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
  return true;
}

Iterable<Node> _codePropertyNodes(Iterable<Node> nodes) sync* {
  for (final node in nodes) {
    yield node;
    yield* _codePropertyNodes(node.children);
  }
}

/// Changes one code prop without moving the caret or saving unrelated fields in undo.
Future<bool> changeCollabCodeProperty(EditorState state, String blockId, String property, Object? value) async {
  if (state.isDisposed || !state.editable) return false;
  final attribute = collabCodePropertyAttributes[property];
  if (attribute == null) return false;
  if (property == 'lang' && (value is! String || value.trim().isEmpty || value.length > 80)) {
    return false;
  }
  if (property == 'blockName' && value != null && (value is! String || value.length > 256)) {
    return false;
  }
  if (property == 'collapse' && value != null && value is! bool) return false;
  final node = _codePropertyNodes(state.document.root.children)
      .where(
        (node) =>
            node.type == csesCodeBlockType &&
            node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] == blockId,
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
  await state.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
  return true;
}

/// 类型转换待消费的来源身份；Rust 完成替换后清除，不保存为共享属性。
const csesReplacementSourceAttribute = 'cses_replacement_source';

/// Registers the collaborative script attributes with AppFlowy's IME.
///
/// AppFlowy validates collapsed-selection styles before inserting text. Custom
/// attributes must be explicitly registered so newly typed superscript and
/// subscript text follows the same path as its built-in rich-text styles.
/// Desktop typography keys also participate in caret inheritance and IME slicing.
void registerCsesRichTextAttributes() {
  registerEditorTextAttributes([csesSuperscriptAttribute, csesSubscriptAttribute, ...collabTypographyKeys]);
}

/// 不可变富文本片段，行内公式/用户/会议/任务/文档提及仅占一个 U+FFFC，使用属性投影恢复原生对象。
/// 调用方持有原文；该类型不创建编辑器、连接或可释放资源。
/// ```dart
/// import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
/// const formula = CollabEditorTextSegment(text: '\uFFFC', inlineLatex: 'x^2');
/// ```
final class CollabEditorTextSegment {
  /// [href] 是原始链接地址，null 为普通正文，正式文档映射到 a:link。
  /// [text] 为正文或公式单字符位置，[inlineLatex] 非 null 时只允许 U+FFFC。
  /// [inlineMention] 为用户/实体显示名，[mentionId] 为稳定ID，两者成对且与公式互斥。
  /// [mentionType] 为meeting/task/doc时展示对应实体，null兼容已有用户；[mentionAttributes] 为四类提及原生属性JSON，
  /// 保留删除后撤销所需的业务信息，不能作为编辑实体业务数据的补丁。
  /// [bold]、[italic]、[underline]、[strikethrough]、[code] 默认 false，分别控制对应格式。
  /// [textColor] 和 [backgroundColor] 为原始颜色字符串，null 表示未显式指定。
  /// [typography] 为字体、字号和字距白名单 JSON，null 继承段落样式。
  /// [superscript]、[subscript] 默认 false，分别控制上下标；原文及属性不自动规范化。
  const CollabEditorTextSegment({
    required this.text,
    this.href,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.code = false,
    this.textColor,
    this.backgroundColor,
    this.superscript = false,
    this.subscript = false,
    this.inlineLatex,
    this.inlineMention,
    this.mentionId,
    this.mentionType,
    this.mentionAttributes,
    this.typography,
  });

  /// 正文文本；行内公式必须为单个 U+FFFC。
  final String text;

  /// 可选原始链接地址；独立保留格式，不推导或改写展示文字。
  final String? href;

  /// 是否加粗，默认 false。
  final bool bold;

  /// 是否斜体，默认 false。
  final bool italic;

  /// 是否有下划线，默认 false。
  final bool underline;

  /// 是否有删除线，默认 false。
  final bool strikethrough;

  /// 是否为行内代码样式，默认 false。
  final bool code;

  /// 显式前景颜色原值，null 时继承正文。
  final String? textColor;

  /// Inline highlight serialized from AppFlowy's `bg_color` delta attribute.
  ///
  /// The value is an ARGB string such as `0x4dffc107`; keeping the alpha in
  /// the payload makes the same highlight render consistently after a remote
  /// Yrs update is converted back into an AppFlowy document.
  final String? backgroundColor;

  /// 是否为上标，默认 false。
  final bool superscript;

  /// 是否为下标，默认 false。
  final bool subscript;

  /// 行内公式源码；非 null 时 text 为单个 U+FFFC，原生层恢复 {latex: …} 对象。
  final String? inlineLatex;

  /// 用户/实体显示名；非 null 时仅占一个 U+FFFC，不写为普通文字。
  final String? inlineMention;

  /// 用户/实体稳定 ID；与显示名成对，null 表示无提及对象。
  final String? mentionId;

  /// meeting/task/doc区分三类实体；null兼容历史用户投影，不使用实体ID加载人员头像。
  final String? mentionType;

  /// 四类提及原始属性JSON快照；历史/手工用户投影可为null，正式投影最大65536字节。
  final String? mentionAttributes;

  /// 字体、字号和字距原始 JSON，null 时继承；不携带链接或业务属性。
  final String? typography;

  /// 是否保留显式分段；链接及公式/提及即使没有其他格式也保留地址或对象信息。
  bool get isStyled =>
      typography != null ||
      href != null ||
      bold ||
      italic ||
      underline ||
      strikethrough ||
      code ||
      textColor != null ||
      backgroundColor != null ||
      superscript ||
      subscript ||
      inlineLatex != null ||
      inlineMention != null;

  /// AppFlowy 内存属性；href映射内置链接键，inlineLatex使用私有对象键。
  Attributes get attributes => {
    if (typography != null) ...Map<String, dynamic>.from(jsonDecode(typography!) as Map),
    if (href != null) AppFlowyRichTextKeys.href: href,
    if (bold) AppFlowyRichTextKeys.bold: true,
    if (italic) AppFlowyRichTextKeys.italic: true,
    if (underline) AppFlowyRichTextKeys.underline: true,
    if (strikethrough) AppFlowyRichTextKeys.strikethrough: true,
    if (code) AppFlowyRichTextKeys.code: true,
    if (textColor != null) AppFlowyRichTextKeys.textColor: textColor,
    if (backgroundColor != null) AppFlowyRichTextKeys.backgroundColor: backgroundColor,
    if (superscript) csesSuperscriptAttribute: true,
    if (subscript) csesSubscriptAttribute: true,
    if (inlineLatex != null) collabInlineLatexAttribute: inlineLatex,
    if (inlineMention != null) collabInlineMentionAttribute: inlineMention,
    if (mentionId != null) collabMentionIdAttribute: mentionId,
    if (mentionType != null) collabMentionTypeAttribute: mentionType,
    if (mentionAttributes != null) collabMentionAttributesAttribute: mentionAttributes,
  };

  /// 基于原文、链接、格式与公式/提及身份及实体属性快照计算哈希。
  @override
  int get hashCode => Object.hash(
    text,
    href,
    bold,
    italic,
    underline,
    strikethrough,
    code,
    textColor,
    backgroundColor,
    superscript,
    subscript,
    inlineLatex,
    inlineMention,
    mentionId,
    mentionType,
    mentionAttributes,
    typography,
  );

  /// 将 [other] 与当前不可变片段的全部字段比较。
  @override
  bool operator ==(Object other) {
    return other is CollabEditorTextSegment &&
        other.text == text &&
        other.href == href &&
        other.bold == bold &&
        other.italic == italic &&
        other.underline == underline &&
        other.strikethrough == strikethrough &&
        other.code == code &&
        other.textColor == textColor &&
        other.backgroundColor == backgroundColor &&
        other.superscript == superscript &&
        other.subscript == subscript &&
        other.inlineLatex == inlineLatex &&
        other.inlineMention == inlineMention &&
        other.mentionId == mentionId &&
        other.mentionType == mentionType &&
        other.mentionAttributes == mentionAttributes &&
        other.typography == typography;
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
  /// [paragraphStyle] 为段落默认字符/下一段及排版字段的原始投影，null 表示未设置。
  /// [code] 为代码头部，[resource] 为特殊块属性，[blockBackgroundColor]、[blockBorderColor] 为块颜色，
  /// [parentId] 为容器身份，[calloutPrefix]、[blockTextColor] 为高亮块前缀/文字颜色。
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
    this.paragraphStyle,
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

  /// 已适配特殊块的属性载体；分割线保存样式，Mermaid 保存共享视图，资源块保存元数据。
  final CollabResource? resource;

  /// 段落族字段只读投影；显式 propertyEdits 表达本次字段修改。
  final CollabResource? paragraphStyle;

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
    paragraphStyle,
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
        other.paragraphStyle == paragraphStyle &&
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
/// AppFlowy owns rendering, selection and IME. Unbound editors use local undo;
/// a collaboration owner can delegate history to Rust/Yrs, which owns block
/// order, block type metadata and native text/props/children. 正式图片的题注保留在
/// image 专属投影中，UI 仍是一个根级资源节点，不把题注混入根顺序。
/// ```dart
/// import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
/// final adapter = AppFlowyBlockEditorAdapter(onLocalBlocksChanged: (blocks) {});
/// // 宿主将 Rust 投影交给 adapter.replaceFromRemote(blocks)。
/// adapter.dispose();
/// ```
final class AppFlowyBlockEditorAdapter {
  /// [onLocalBlocksChanged] 在本地事务完成后接收完整同步投影，远端回放不调用。
  /// [editing] 为外部借用的编辑会话；null按旧契约自建并拥有会话。
  /// [initialBlocks] 仅用于自建会话，传入editing时须为空。
  /// [onTransactionPreparing] 可选，供原生历史在树改变前捕获稳定选区。
  /// dispose卸载同步绑定，只有自建会话才同时释放正文。
  AppFlowyBlockEditorAdapter({
    required this.onLocalBlocksChanged,
    this.onTransactionPreparing,
    List<CollabEditorBlock> initialBlocks = const [],
    DocumentEditorController? editing,
  }) : editing =
           editing ??
           DocumentEditorController(
             document: _createDocument(initialBlocks),
             commandContext: const EditorCommandContext.legacy(),
           ),
       _ownsEditing = editing == null {
    if (editing != null && initialBlocks.isNotEmpty) throw ArgumentError('借用编辑会话时不能提供初始同步块');
    registerCsesRichTextAttributes();
    _lastPublishedBlocks = _readBlocks(editorState, const []);
    _binding = EditorSynchronizationBinding(
      prepare: _prepareTransaction,
      validate: (event) => _protectUnsupportedBlocks(event.$2),
      didApply: _handleTransaction,
    );
    this.editing.attachSynchronization(_binding);
  }

  /// 编辑器内用于同步投影的稳定块身份属性。
  static const collabBlockIdAttribute = 'cses_collab_block_id';

  /// 本地事务完成后的同步回调，由数据层持有。
  final LocalEditorBlocksChanged onLocalBlocksChanged;

  /// Optional borrowed hook capturing stable selection before a local tree edit.
  /// Called synchronously with the prepared transaction; never for projection.
  final void Function(Transaction transaction)? onTransactionPreparing;

  /// 绑定的独立编辑会话，默认自建时归本适配器释放。
  final DocumentEditorController editing;
  final bool _ownsEditing;
  late final EditorSynchronizationBinding _binding;

  /// 适配器借用的正文，不单独释放外部会话的状态。
  EditorState get editorState => editing.editorState;

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

  List<CollabEditorBlock> get blocks => _readBlocks(editorState, _lastPublishedBlocks);

  String get text => blocks.map((block) => block.text).join('\n');

  /// Applies canonical Rust/Yrs blocks without publishing them as local edits.
  /// 行内公式或格式更新采用 Delta 局部差量，保留对象外的正文与光标位置。
  /// [nextBlocks] 是当前权威投影，空列表显示一个 UI 空段落；Future 在事务完成后结束。
  /// 块身份、类型、顺序一致时原位更新文字、媒体、分页符、分割线、公式及会议/任务引用属性，保留组件、选区与输入连接；
  /// URL、尺寸和题注复用节点映射，移除的可选投影显式清空。结构不同才重建节点。
  /// 不记录本地撤销或发送 WS；销毁后不执行，事务异常向调用边界传播。
  /// 表格路径/单元格正文或绘图源码/结构改变会清除本地路径历史及选区，避免过期撤销覆盖远端内容；布局属性更新保留历史。
  /// 普通正文、格式或结构变化会移除未受稳定身份/指纹保护的历史项，不自动转换旧文字撤销。
  /// 此失效策略仅影响本地路径栈，不清空外部原生历史所有者的栈。
  /// 原生历史模式将选区通知延后至所有者完成相对书签解析，避免中间旧路径关闭输入连接。
  /// 正式编号及原始设置更新内存投影，不进入历史；成功转换后清除 replacesId。
  Future<void> replaceFromRemote(List<CollabEditorBlock> nextBlocks) async {
    if (_disposed) return;
    await editing.project(() => _replaceFromRemote(nextBlocks));
  }

  /// 在隔离同步回送的范围中回放 [nextBlocks]，沿用原投影与历史失效策略。
  /// 权威回放不修改 editable，不将只读或预览短暂变为可写。
  Future<void> _replaceFromRemote(List<CollabEditorBlock> nextBlocks) async {
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
              _nodeBlockType(currentNodes[index]) == targetBlocks[index].blockType &&
              currentBlocks[index].parentId == targetBlocks[index].parentId &&
              (currentNodes[index].type == csesUnsupportedBlockType ||
                  isCollabContainerType(currentNodes[index].type) ||
                  currentNodes[index].type == collabDividerType ||
                  currentNodes[index].type == collabPageDividerType ||
                  currentNodes[index].type == collabFormulaType ||
                  currentNodes[index].type == collabMeetingType ||
                  (currentNodes[index].type == collabTaskCardType || currentNodes[index].type == collabKrType) ||
                  currentNodes[index].delta != null ||
                  _isUrlBackedBlock(targetBlocks[index].blockType)),
        ).every((matches) => matches);
    final transaction = editorState.transaction;

    if (canPatchInPlace) {
      for (var index = 0; index < currentNodes.length; index += 1) {
        final node = currentNodes[index];
        final target = targetBlocks[index];
        if (node.type == csesUnsupportedBlockType) continue;
        if (collabTableTypes.contains(target.blockType) ||
            _isUrlBackedBlock(target.blockType) ||
            target.blockType == collabMermaidType ||
            target.blockType == collabDividerType ||
            target.blockType == collabPageDividerType ||
            target.blockType == collabFormulaType ||
            target.blockType == collabMeetingType ||
            (target.blockType == collabTaskCardType || target.blockType == collabKrType)) {
          if (currentBlocks[index] != target) {
            // 统一复用创建节点时的协议映射，避免 URL/布局/题注形成两套编码。
            // updateNode 合并属性，故可选图片投影缺失时需要显式 null 删除旧值。
            transaction.updateNode(node, {
              ..._nodeFromBlock(target).attributes,
              if (target.blockType == ImageBlockKeys.type && target.image == null) collabImageAttribute: null,
            });
          }
          continue;
        }
        final currentSegments = _readNodeSegments(node);
        if (isCollabContainerType(node.type)) {
          // Container content is represented by its child nodes.
        } else if (!_segmentsEqual(currentSegments, target.segments)) {
          final currentDelta = node.delta ?? Delta();
          final patch = currentDelta.diff(_deltaFromBlock(target));
          if (patch.isNotEmpty) {
            transaction.add(UpdateTextOperation(node.path, patch, patch.invert(currentDelta)));
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
        if (node.type == TodoListBlockKeys.type && node.attributes[TodoListBlockKeys.checked] != target.checked) {
          transaction.updateNode(node, {TodoListBlockKeys.checked: target.checked});
        }
        if (supportsCollabParagraph(node) &&
            readCollabParagraph(node).properties != target.paragraphStyle?.properties) {
          transaction.updateNode(node, paragraphNodeAttributes(target.paragraphStyle));
        }
        final targetIndent = _supportsIndent(target.blockType) ? target.indent : 0;
        if (node.attributes[csesCalloutPrefixAttribute] != target.calloutPrefix ||
            node.attributes[csesBlockTextColorAttribute] != target.blockTextColor ||
            node.attributes[csesBlockBackgroundColorAttribute] != target.blockBackgroundColor ||
            node.attributes[csesBlockBorderColorAttribute] != target.blockBorderColor ||
            node.attributes[blockComponentAlign] != target.alignment ||
            node.attributes[csesBlockIndentAttribute] != targetIndent ||
            _readOrdered(node) != target.ordered ||
            _readCode(node) != target.code ||
            node.attributes[csesReplacementSourceAttribute] != target.replacesId) {
          transaction.updateNode(node, {
            csesCalloutPrefixAttribute: target.calloutPrefix,
            csesBlockTextColorAttribute: target.blockTextColor,
            csesBlockBackgroundColorAttribute: target.blockBackgroundColor,
            csesBlockBorderColorAttribute: target.blockBorderColor,
            blockComponentBackgroundColor: parseCollabBlockColor(target.blockBackgroundColor)?.toHex(),
            blockComponentAlign: target.alignment,
            csesBlockIndentAttribute: targetIndent,
            csesOrderedAttribute: target.ordered?.toJson(),
            collabCodeAttribute: target.code?.toJson(),
            for (final entry in collabCodePropertyAttributes.entries)
              entry.value: target.code?.propertyAttribute(entry.key),
            csesOrderedNumberingAttribute: target.ordered?.numbering,
            csesOrderedTargetAttribute: target.ordered == null ? null : target.id,
            csesReplacementSourceAttribute: target.replacesId,
          });
        }
      }
    } else {
      if (currentRootNodes.isNotEmpty) {
        transaction.deleteNodesAtPath([0], currentRootNodes.length);
      }
      transaction.add(InsertOperation([0], _nodesFromBlocks(targetBlocks)), transform: false);
    }

    if (transaction.operations.isEmpty) {
      _lastPublishedBlocks = targetBlocks;
      return;
    }
    final externalHistory = editorState.undoManager.externalHistory != null;
    final invalidateTableHistory = _tableContentChanged(currentBlocks, targetBlocks);
    if (!externalHistory && (invalidateTableHistory || _mermaidContentChanged(currentBlocks, targetBlocks))) {
      editorState.undoManager.undoStack.clear();
      editorState.undoManager.redoStack.clear();
      // 路径历史不能越过远端换行/删行/合并或正文覆盖后继续作用于其他单元格。
      transaction.afterSelection = null;
      editorState.selection = null;
    } else if (!externalHistory) {
      final structureChanged = _historyStructureChanged(currentBlocks, targetBlocks);
      if (structureChanged || _historyContentChanged(currentBlocks, targetBlocks)) {
        _discardUnsafeHistory(structureChanged: structureChanged);
      }
    }
    _applyingRemote = true;
    try {
      // Trusted remote replay bypasses local permission/pause without changing
      // editableNotifier, so preview and in-flight edit sessions remain intact.
      // 当前AppFlowy在返回Future前同步完成树更新；不能把本地发布抑制延长到
      // Future的微任务结束，否则刚插入表格后的立即撤销会只改UI而漏掉原生写入。
      final completion = editorState.apply(
        transaction,
        isRemote: true,
        withUpdateSelection: !externalHistory,
        options: const ApplyOptions(recordUndo: false, inMemoryUpdate: true),
      );
      _lastPublishedBlocks = targetBlocks;
      _applyingRemote = false;
      await completion;
    } finally {
      _applyingRemote = false;
    }
  }

  /// 比较 [before] 和 [after] 的块顺序、身份、类型及父结构，判断路径字段历史是否过期。
  static bool _historyStructureChanged(List<CollabEditorBlock> before, List<CollabEditorBlock> after) {
    if (before.length != after.length) return true;
    for (var i = 0; i < before.length; i++) {
      final old = before[i];
      final next = after[i];
      if (old.id != next.id || old.parentId != next.parentId || old.blockType != next.blockType) {
        return true;
      }
    }
    return false;
  }

  /// 比较同结构的 [before] 和 [after] 的完整正文，忽略等价分段。
  /// 调用方先排除结构变化；普通正文、代码和行内格式的旧全文历史不能跨越内容变化。
  static bool _historyContentChanged(List<CollabEditorBlock> before, List<CollabEditorBlock> after) {
    for (var i = 0; i < before.length; i++) {
      final old = before[i];
      final next = after[i];
      if (old.text != next.text ||
          (!_segmentsEqual(old.segments, next.segments) &&
              _deltaFromBlock(old).diff(_deltaFromBlock(next)).isNotEmpty)) {
        return true;
      }
    }
    return false;
  }

  /// 移除借用编辑器中不能安全重放的撤销及重做项，保留稳定身份和指纹保护命令。
  /// 尚未实现普通文字历史的协同转换，因此宁可丢弃旧操作，也不覆盖远端或邻居正文。
  /// [structureChanged]为false时允许原路径上的独立字段补丁，true时要求稳定身份保护。
  /// 逐栈恢复保留项的原顺序；不执行事务、恢复旧选区或发布协同更新。
  void _discardUnsafeHistory({required bool structureChanged}) {
    for (final stack in [editorState.undoManager.undoStack, editorState.undoManager.redoStack]) {
      final retained = [
        for (var item = stack.pop(); item != null; item = stack.pop())
          if (_stableHistory(item.operations, structureChanged: structureChanged)) item,
      ];
      for (final item in retained.reversed) {
        stack.push(item);
      }
    }
  }

  /// 判断整项 [operations] 是否具有现有的稳定身份/指纹回放保护。
  /// 原子公式、卡片及链接转换命令独立封闭历史并在before阶段校验整组；
  /// [structureChanged]区分仅改正文和路径变化；前者保留独立字段补丁，后者要求稳定目标。
  /// 混入全文Delta或普通结构操作的非原子命令不保留。
  static bool _stableHistory(List<Operation> operations, {required bool structureChanged}) {
    if (operations.isEmpty) return false;
    if (operations.whereType<UpdateOperation>().any(
      (op) =>
          op.attributes[collabInlineFormulaCommandAttribute] is String ||
          op.attributes[collabMentionCardCommandAttribute] is String ||
          op.attributes[collabLinkViewCommand] is String,
    )) {
      return true;
    }
    return operations.every(
      (op) =>
          op is UpdateOperation &&
          !op.attributes.containsKey(blockComponentDelta) &&
          (!structureChanged ||
              [
                collabParagraphTargetAttribute,
                collabCodeTargetAttribute,
                collabResourceTargetAttribute,
                csesCalloutTargetAttribute,
                csesOrderedTargetAttribute,
              ].any((key) => op.attributes[key] is String)),
    );
  }

  /// 比较 [before] 与 [after] 的绘图源码和结构，远端变更后使路径历史失效。
  /// 现有编辑器不对历史执行文本OT；不能让旧偏移覆盖远端源码或另一个块。
  /// 远端共享视图变化及绘图存在时的结构变更清空整个历史；普通正文另由通用安全策略处理。
  static bool _mermaidContentChanged(List<CollabEditorBlock> before, List<CollabEditorBlock> after) {
    if (![...before, ...after].any((b) => b.blockType == collabMermaidType)) {
      return false;
    }
    if (before.length != after.length) return true;
    for (var index = 0; index < before.length; index++) {
      final old = before[index];
      final next = after[index];
      if (old.id != next.id || old.parentId != next.parentId || old.blockType != next.blockType) {
        return true;
      }
      if (old.blockType == collabMermaidType &&
          (old.resource ?? const CollabResource()).field('mode') !=
              (next.resource ?? const CollabResource()).field('mode')) {
        return true;
      }
      if (old.blockType == collabMermaidSourceType &&
          (old.text != next.text || !_segmentsEqual(old.segments, next.segments))) {
        return true;
      }
    }
    return false;
  }

  /// 比较 [before] 与 [after] 的表格路径及正文；布局属性变化不使历史失效。
  /// 远端结构或单元格正文变化会清除本地路径历史，避免撤销写入另一个单元格或覆盖新正文。
  static bool _tableContentChanged(List<CollabEditorBlock> before, List<CollabEditorBlock> after) {
    if (![...before, ...after].any((b) => collabTableTypes.contains(b.blockType))) {
      return false;
    }
    if (before.length != after.length) return true;
    final byId = {for (final block in before) block.id: block};
    for (var i = 0; i < before.length; i++) {
      final old = before[i];
      final next = after[i];
      if (old.id != next.id || old.parentId != next.parentId || old.blockType != next.blockType) {
        return true;
      }
      var parent = old;
      var inTable = collabTableTypes.contains(parent.blockType);
      for (var depth = 0; !inTable && parent.parentId != null && depth < 256; depth++) {
        final ancestor = byId[parent.parentId];
        if (ancestor == null) break;
        parent = ancestor;
        inTable = collabTableTypes.contains(parent.blockType);
      }
      if (inTable &&
          (old.text != next.text ||
              (!_segmentsEqual(old.segments, next.segments) &&
                  _deltaFromBlock(old).diff(_deltaFromBlock(next)).isNotEmpty))) {
        return true;
      }
    }
    return false;
  }

  /// 在本地 [value] 的默认格式处理前重定位稳定身份与历史，不负责输入状态。
  void _prepareTransaction(EditorTransactionValue value) {
    if (_disposed || _applyingRemote) return;
    resolveCollabLinkViewCommand(editorState, value.$2, (id) {
      final seen = <String>{};
      while (_replacementIds.containsKey(id) && seen.add(id)) {
        id = _replacementIds[id]!;
      }
      return id;
    });
    resolveCollabMentionCardCommand(editorState, value.$2);
    resolveCollabInlineFormulaCommands(editorState, value.$2);
    _resolveNumberingTargets(value.$2);
    onTransactionPreparing?.call(value.$2);
  }

  /// 在本地[value]完成输入历史维护后发布同步快照，准备阶段已重定位稳定身份；
  /// 类型转换生成新身份并记录来源供Rust保留扩展数据；提及卡片及链接视图转换历史在写入前整组预检，并按身份链重定位。
  /// 远端回放及销毁后不发布；Undo/Redo 的历史身份经文档内映射恢复为当前可替换来源。
  /// 仅明确修改编号设置属性的 UpdateOperation 生成编号写入意图；普通文字/结构快照
  /// 即使携带旧设置也不会覆盖原生 start/continuePrevious。分割线、公式和绘图mode同样只发布明确的单字段补丁。
  /// 撤销和重做复用相同路径。
  void _handleTransaction(EditorTransactionValue value) {
    if (_disposed || _applyingRemote) {
      return;
    }
    final numberingNodes = <Node>{};
    final codeEdits = <Node, Set<String>>{};
    final resourceEdits = <Node, Set<String>>{};
    final paragraphEdits = <Node, Set<String>>{};
    for (final operation in value.$2.operations.whereType<UpdateOperation>()) {
      final node = editorState.getNodeAtPath(operation.path);
      if (node != null && supportsCollabParagraph(node)) {
        for (final key in collabParagraphKeys) {
          if (operation.attributes.containsKey(paragraphPropertyAttribute(key))) {
            paragraphEdits.putIfAbsent(node, () => {}).add(key);
          }
        }
      }
      if (node != null &&
          node.type == collabMermaidType &&
          operation.attributes.containsKey(collabMermaidModeAttribute)) {
        resourceEdits.putIfAbsent(node, () => {}).add('mode');
      }
      if (node != null && node.type == collabFormulaType && operation.attributes.containsKey(collabFormulaAttribute)) {
        resourceEdits.putIfAbsent(node, () => {}).add('latex');
      }
      if (node != null && node.type == collabMeetingType) {
        for (final key in collabMeetingKeys) {
          if (operation.attributes.containsKey(meetingPropertyAttribute(key))) {
            resourceEdits.putIfAbsent(node, () => {}).add(key);
          }
        }
      }
      if (node != null && node.type == collabDividerType) {
        for (final key in collabDividerKeys) {
          if (operation.attributes.containsKey(dividerPropertyAttribute(key))) {
            resourceEdits.putIfAbsent(node, () => {}).add(key);
          }
        }
      }
      if (node != null && isCollabResourceType(node.type)) {
        if (operation.attributes.containsKey(csesEmbedUrlAttribute)) {
          resourceEdits.putIfAbsent(node, () => {}).add('url');
        }
        for (final key in collabResourceKeys) {
          if (operation.attributes.containsKey(resourcePropertyAttribute(key))) {
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
    for (final operation in value.$2.operations.whereType<InsertOperation>()) {
      for (final node in _flattenNodes(operation.nodes)) {
        if (!supportsCollabParagraph(node)) continue;
        paragraphEdits
            .putIfAbsent(node, () => {})
            .addAll(collabParagraphKeys.where((key) => node.attributes.containsKey(paragraphPropertyAttribute(key))));
      }
    }
    final nextBlocks = _readBlocks(
      editorState,
      _lastPublishedBlocks,
      numberingNodes: numberingNodes,
      codeEdits: codeEdits,
      resourceEdits: resourceEdits,
      paragraphEdits: paragraphEdits,
    );
    if (_blocksEqual(nextBlocks, _lastPublishedBlocks)) {
      return;
    }
    _lastPublishedBlocks = List<CollabEditorBlock>.unmodifiable(nextBlocks);
    onLocalBlocksChanged(_lastPublishedBlocks);
  }

  /// 在 [transaction] 写入前跟踪路径，阻止未知占位及其父容器被删除或改写。
  /// 表格结构由原生完整网格预检；含占位的表格结构操作仍整体拒绝，列宽字段可独立修改。
  void _protectUnsupportedBlocks(Transaction transaction) {
    final paths = _flattenNodes(
      editorState.document.root.children,
    ).where((node) => node.type == csesUnsupportedBlockType).map((node) => List<int>.from(node.path)).toList();
    bool containsPlaceholder(Node node) =>
        node.type == csesUnsupportedBlockType || node.children.any(containsPlaceholder);
    bool prefix(Path a, Path b) => a.length <= b.length && List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
    var blocked = false;
    for (final operation in transaction.operations) {
      final path = operation.path;
      if (operation is InsertOperation) {
        blocked =
            operation.nodes.any(containsPlaceholder) || paths.any((p) => p.length < path.length && prefix(p, path));
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
      if (path.isNotEmpty && (operation is InsertOperation || operation is DeleteOperation)) {
        final count = operation is InsertOperation
            ? operation.nodes.length
            : -(operation as DeleteOperation).nodes.length;
        for (final p in paths) {
          if (p.length >= path.length && prefix(path.parent, p) && p[path.length - 1] >= path.last) {
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
              (operation.attributes.containsKey(collabParagraphTargetAttribute) ||
                  operation.attributes.containsKey(collabCodeTargetAttribute) ||
                  operation.attributes.containsKey(collabResourceTargetAttribute)),
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
      if (operation.attributes.containsKey(collabParagraphTargetAttribute)) {
        var id = operation.attributes[collabParagraphTargetAttribute] as String?;
        final seen = <String>{};
        while (id != null && _replacementIds.containsKey(id) && seen.add(id)) {
          id = _replacementIds[id];
        }
        final node = _flattenNodes(
          editorState.document.root.children,
        ).where((n) => _nodeBlockId(n) == id && supportsCollabParagraph(n)).firstOrNull;
        if (node != null && editorState.editable) {
          operations.add(_relocateParagraphHistory(operation, node.path));
        }
        continue;
      }
      if (operation.attributes.containsKey(collabResourceTargetAttribute)) {
        if (!editorState.editable) continue;
        final id = operation.attributes[collabResourceTargetAttribute];
        final kind = operation.attributes[collabResourceKindAttribute];
        final node = _flattenNodes(
          editorState.document.root.children,
        ).where((n) => _nodeBlockId(n) == id && n.type == kind).firstOrNull;
        if (node != null) {
          operations.add(_relocateParagraphHistory(operation, node.path));
        }
        continue;
      }
      final isCallout = operation.attributes.containsKey(csesCalloutTargetAttribute);
      final isCode = operation.attributes.containsKey(collabCodeTargetAttribute);
      final isOrdered = operation.attributes.containsKey(csesOrderedNumberingAttribute);
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
      if (node != null) {
        operations.add(_relocateParagraphHistory(operation, node.path));
      }
    }
    transaction.operations = operations;
  }

  /// 将借用的 [operation] 重定位到 [path] 并保留本地输入历史，返回新的操作对象。
  Operation _relocateParagraphHistory(UpdateOperation operation, Path path) {
    final relocated = operation.copyWith(path: path) as UpdateOperation;
    editing.transferHistory(operation, relocated);
    return relocated;
  }

  /// 卸载同步事务绑定并释放自建会话；外部编辑会话保持有效，重复调用安全。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    editing.detachSynchronization(_binding);
    if (_ownsEditing) editing.dispose();
  }

  /// 将初始 [blocks] 转为自建编辑会话拥有的文档，空列表创建可输入段落。
  static Document _createDocument(List<CollabEditorBlock> blocks) {
    final nodes = blocks.isEmpty ? [_newEmptyParagraphNode()] : _nodesFromBlocks(blocks);
    return Document(
      root: Node(type: 'page', id: 'cses-demo-page', children: nodes),
    );
  }

  static List<CollabEditorBlock> _emptyDocumentBlocks(List<CollabEditorBlock> current) {
    if (current.length == 1 && current.first.blockType == ParagraphBlockKeys.type && current.first.text.isEmpty) {
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

  /// 深度优先遍历借用的 [nodes] 及已适配容器子树，保留文档顺序。
  static Iterable<Node> _flattenNodes(Iterable<Node> nodes) sync* {
    for (final node in nodes) {
      yield node;
      if (isCollabContainerType(node.type)) {
        yield* _flattenNodes(node.children);
      }
    }
  }

  /// 按 [blocks] 的前序父身份构建编辑树；各正文保留独立节点与稳定身份。
  static List<Node> _nodesFromBlocks(List<CollabEditorBlock> blocks) {
    final nodes = {for (final block in blocks) block.id: _nodeFromBlock(block)};
    final roots = <Node>[];
    for (final block in blocks) {
      final node = nodes[block.id]!;
      final parent = nodes[block.parentId];
      if (parent != null && isCollabContainerType(parent.type)) {
        parent.insert(node);
      } else {
        roots.add(node);
      }
    }
    return roots;
  }

  /// 将权威 [block] 转为 AppFlowy 节点，图片保存强类型专属数据的 Map 投影。
  /// 题注留在资源属性而非 AppFlowy children；实际父子关系由 Rust 的共享类型持有。
  /// KR只投影会议引用，不缓存业务列表；Mermaid 保留容器及独立源码 Delta；表格布局及任务卡片属性只读投影；其他无正文块保留各自白名单属性，均不生成Delta。
  /// 段落格式及其历史目标标记仅用于段落族；代码块沿用自身属性和正文历史。
  /// 分页符使用无 Delta、无子块的独立类型；仅构建内存节点，不写入原生文档或取得资源所有权。
  static Node _nodeFromBlock(CollabEditorBlock block) {
    if (collabTableTypes.contains(block.blockType)) {
      return Node(
        type: block.blockType,
        id: block.id,
        attributes: {
          collabBlockIdAttribute: block.id,
          collabTableLayoutAttribute: block.resource?.toJson() ?? const {'properties': '{}'},
          csesBlockBackgroundColorAttribute: block.blockBackgroundColor,
          csesBlockBorderColorAttribute: block.blockBorderColor,
        },
      );
    }
    if (block.blockType == csesUnsupportedBlockType) {
      return Node(type: csesUnsupportedBlockType, id: block.id, attributes: {collabBlockIdAttribute: block.id});
    }
    if (block.blockType == collabTaskCardType || block.blockType == collabKrType) {
      return Node(
        type: block.blockType,
        id: block.id,
        attributes: {
          collabBlockIdAttribute: block.id,
          collabResourceAttribute: (block.resource ?? const CollabResource()).toJson(),
        },
      );
    }
    if (block.blockType == collabMeetingType) {
      return Node(
        type: collabMeetingType,
        id: block.id,
        attributes: {
          collabBlockIdAttribute: block.id,
          ...CollabMeeting.nodeAttributes(block.resource ?? const CollabResource()),
        },
      );
    }
    if (block.blockType == collabFormulaType) {
      return Node(
        type: collabFormulaType,
        id: block.id,
        attributes: {
          collabBlockIdAttribute: block.id,
          ...collabFormulaNodeAttributes(block.resource ?? const CollabResource()),
        },
      );
    }
    if (block.blockType == collabPageDividerType) {
      return Node(type: collabPageDividerType, id: block.id, attributes: {collabBlockIdAttribute: block.id});
    }
    if (block.blockType == collabDividerType) {
      return Node(
        type: collabDividerType,
        id: block.id,
        attributes: {
          collabBlockIdAttribute: block.id,
          ...CollabDivider.nodeAttributes(block.resource ?? const CollabResource()),
        },
      );
    }
    if (block.blockType == collabMermaidType) {
      return Node(
        type: collabMermaidType,
        id: block.id,
        attributes: {
          collabBlockIdAttribute: block.id,
          ...collabMermaidNodeAttributes(block.resource ?? const CollabResource()),
        },
      );
    }
    if (block.blockType == collabMermaidSourceType) {
      return Node(
        type: collabMermaidSourceType,
        id: block.id,
        attributes: {collabBlockIdAttribute: block.id, blockComponentDelta: _deltaFromBlock(block).toJson()},
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
          if (isCollabResourceType(block.blockType)) ...(block.resource ?? const CollabResource()).nodeAttributes,
          if (isImage) ImageBlockKeys.url: block.text,
          if (!isImage) csesEmbedUrlAttribute: block.text,
          if (isImage) ImageBlockKeys.align: block.alignment,
          if (isImage && block.image != null) collabImageAttribute: block.image!.toJson(),
          collabBlockIdAttribute: block.id,
          csesBlockBackgroundColorAttribute: block.blockBackgroundColor,
          csesBlockBorderColorAttribute: block.blockBorderColor,
          blockComponentBackgroundColor: parseCollabBlockColor(block.blockBackgroundColor)?.toHex(),
          blockComponentAlign: block.alignment,
          csesBlockIndentAttribute: 0,
        },
      );
    }

    final (nodeType, deltaKey, extraAttributes) = switch (block.blockType) {
      final type when type.startsWith('heading_') => (
        HeadingBlockKeys.type,
        HeadingBlockKeys.delta,
        <String, Object>{HeadingBlockKeys.level: int.tryParse(type.substring('heading_'.length))?.clamp(1, 9) ?? 1},
      ),
      BulletedListBlockKeys.type => (BulletedListBlockKeys.type, BulletedListBlockKeys.delta, <String, Object>{}),
      NumberedListBlockKeys.type => (NumberedListBlockKeys.type, NumberedListBlockKeys.delta, <String, Object>{}),
      TodoListBlockKeys.type => (
        TodoListBlockKeys.type,
        TodoListBlockKeys.delta,
        <String, Object>{TodoListBlockKeys.checked: block.checked},
      ),
      QuoteBlockKeys.type => (QuoteBlockKeys.type, QuoteBlockKeys.delta, <String, Object>{}),
      csesCodeBlockType => (csesCodeBlockType, blockComponentDelta, <String, Object>{}),
      _ => (ParagraphBlockKeys.type, ParagraphBlockKeys.delta, <String, Object>{}),
    };
    return Node(
      type: nodeType,
      id: block.id,
      attributes: {
        deltaKey: _deltaFromBlock(block).toJson(),
        if (nodeType != csesCodeBlockType) ...{
          ...paragraphNodeAttributes(block.paragraphStyle),
          collabParagraphTargetAttribute: block.id,
        },
        collabBlockIdAttribute: block.id,
        if (block.code != null) collabCodeAttribute: block.code!.toJson(),
        if (block.code != null) ...block.code!.nodeAttributes,
        if (block.ordered != null) csesOrderedAttribute: block.ordered!.toJson(),
        if (block.ordered != null) csesOrderedNumberingAttribute: block.ordered!.numbering,
        if (block.ordered != null) csesOrderedTargetAttribute: block.id,
        if (block.replacesId != null) csesReplacementSourceAttribute: block.replacesId,
        csesBlockBackgroundColorAttribute: block.blockBackgroundColor,
        csesBlockBorderColorAttribute: block.blockBorderColor,
        blockComponentBackgroundColor: parseCollabBlockColor(block.blockBackgroundColor)?.toHex(),
        blockComponentAlign: block.alignment,
        csesBlockIndentAttribute: _supportsIndent(block.blockType) ? block.indent : 0,
        ...extraAttributes,
      },
    );
  }

  /// 从借用 [state] 读取完整根投影，[previous] 用于恢复身份及识别 flavour 转换。
  /// 图片属性显式恢复为强类型；远端回放期间的发布抑制由调用方负责。
  /// 转换生成新的协同身份，历史身份链保证 Undo/Redo 仍替换当前块，保留 Rust 原生扩展属性。
  /// [numberingNodes] 默认空集合，只有当前本地事务明确修改编号设置的节点才生成写入意图。
  /// [paragraphEdits] 指定当前事务修改的段落字段，默认不写入共享设置。
  /// [codeEdits] 和 [resourceEdits] 默认空，分别指定代码头部及资源/分割线/公式/绘图视图的显式字段修改；
  /// 仅指定字段产生补丁，其他原始属性保持只读投影，不重放到权威文档。
  /// 恢复为有序列表的历史节点保留其编号投影，Rust 仅在新身份替换时用它初始化原始设置；
  /// 正常新转入有序列表的节点由类型命令移除旧投影，走默认续号。非有序目标清理内存编号数据。
  /// 表格按容器父身份遍历，布局属性只读投影；每个单元格正文仍独立持有Delta。
  List<CollabEditorBlock> _readBlocks(
    EditorState state,
    List<CollabEditorBlock> previous, {
    Set<Node> numberingNodes = const {},
    Map<Node, Set<String>> codeEdits = const {},
    Map<Node, Set<String>> resourceEdits = const {},
    Map<Node, Set<String>> paragraphEdits = const {},
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
      while (!previousById.containsKey(blockId) && _replacementIds.containsKey(blockId)) {
        blockId = _replacementIds[blockId]!;
      }
      final attributeValue = node.attributes[collabBlockIdAttribute];
      final hasExplicitId = attributeValue is String && attributeValue.isNotEmpty;
      if (!hasExplicitId || blockId.isEmpty || seenIds.contains(blockId)) {
        final previousId = index < previous.length ? previous[index].id : null;
        blockId = previousId != null && !explicitIds.contains(previousId) && !seenIds.contains(previousId)
            ? previousId
            : node.id;
      }
      final before = previousById[blockId];
      if (!_applyingRemote &&
          before != null &&
          _formalFlavour(before.blockType) != _formalFlavour(_nodeBlockType(node))) {
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
          if (node.type == NumberedListBlockKeys.type) csesOrderedTargetAttribute: blockId,
        });
      }
      seenIds.add(blockId);
      if (attributeValue != blockId) {
        node.updateAttributes({collabBlockIdAttribute: blockId});
      }
      final paragraph = supportsCollabParagraph(node)
          ? readCollabParagraph(node, edited: paragraphEdits[node] ?? const {})
          : null;
      return CollabEditorBlock(
        paragraphStyle: paragraph != null && (paragraph.values.isNotEmpty || paragraph.propertyEdits != null)
            ? paragraph
            : null,
        id: blockId,
        parentId: isCollabContainerType(node.parent?.type ?? '') ? _nodeBlockId(node.parent!) : null,
        calloutPrefix: node.type == csesCalloutBlockType
            ? node.attributes[csesCalloutPrefixAttribute] as String?
            : null,
        blockTextColor: node.type == csesCalloutBlockType
            ? node.attributes[csesBlockTextColorAttribute] as String?
            : null,
        resource: node.type == collabMermaidType
            ? readCollabMermaidProperties(node.attributes, edited: resourceEdits[node]?.contains('mode') == true)
            : collabTableTypes.contains(node.type)
            ? readCollabTable(node.attributes, before?.resource)
            : node.type == collabKrType
            ? readCollabKr(node.attributes)
            : node.type == collabTaskCardType
            ? CollabTaskCard.read(node.attributes)
            : node.type == collabMeetingType
            ? CollabMeeting.readAttributes(node.attributes, edited: resourceEdits[node] ?? const {})
            : node.type == collabFormulaType
            ? readCollabFormula(node.attributes, edited: resourceEdits[node]?.contains('latex') == true)
            : node.type == collabDividerType
            ? CollabDivider.readAttributes(node.attributes, edited: resourceEdits[node] ?? const {})
            : isCollabResourceType(node.type)
            ? CollabResource.fromAttributes(node.attributes, edited: resourceEdits[node] ?? const {})
            : null,
        code: _readCode(node, editedProperties: codeEdits[node] ?? const {}),
        blockType: _nodeBlockType(node),
        text: _readNodePlainText(node),
        ordered: node.type == NumberedListBlockKeys.type
            ? _readOrdered(node, edited: numberingNodes.contains(node))
            : null,
        replacesId: node.attributes[csesReplacementSourceAttribute] as String?,
        image: node.type == ImageBlockKeys.type && node.attributes[collabImageAttribute] is Map
            ? CollabImage.fromJson(Map<String, dynamic>.from(node.attributes[collabImageAttribute] as Map))
            : null,
        segments: _readNodeSegments(node),
        checked: node.type == TodoListBlockKeys.type && (node.attributes[TodoListBlockKeys.checked] as bool? ?? false),
        blockBackgroundColor: node.attributes[csesBlockBackgroundColorAttribute] as String?,
        blockBorderColor: node.attributes[csesBlockBorderColorAttribute] as String?,
        alignment: _nodeAlignment(node),
        indent: _supportsIndent(_nodeBlockType(node))
            ? (node.attributes[csesBlockIndentAttribute] as int? ?? 0).clamp(0, 6)
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
      node.attributes[csesOrderedNumberingAttribute] as String? ?? ordered.numbering,
      edited: edited,
    );
  }

  static CollabCode? _readCode(Node node, {Set<String> editedProperties = const {}}) {
    final value = node.attributes[collabCodeAttribute];
    return node.type == csesCodeBlockType &&
            (value is Map || collabCodePropertyAttributes.values.any(node.attributes.containsKey))
        ? CollabCode.fromAttributes(node.attributes, editedProperties: editedProperties)
        : null;
  }

  /// 将手机 [type] 归到正式 flavour；标题级别变化仍是同一 paragraph，不替换身份。
  static String _formalFlavour(String type) => type.startsWith('heading_') ? 'paragraph' : type;

  static String _nodeBlockId(Node node) {
    final value = node.attributes[collabBlockIdAttribute];
    return value is String && value.isNotEmpty ? value : node.id;
  }

  /// 将借用[node]映射为投影类型；绘图、表格结构及无正文块保留独立类型。
  static String _nodeBlockType(Node node) {
    if (node.type == collabMermaidType ||
        node.type == collabMermaidSourceType ||
        collabTableTypes.contains(node.type) ||
        isCollabResourceType(node.type) ||
        node.type == collabDividerType ||
        node.type == collabPageDividerType ||
        node.type == collabFormulaType ||
        node.type == collabMeetingType ||
        (node.type == collabTaskCardType || node.type == collabKrType)) {
      return node.type;
    }
    if (node.type == csesUnsupportedBlockType) return csesUnsupportedBlockType;
    if (node.type == csesCalloutBlockType) return csesCalloutBlockType;
    return switch (node.type) {
      HeadingBlockKeys.type => 'heading_${(node.attributes[HeadingBlockKeys.level] as int? ?? 1).clamp(1, 9)}',
      BulletedListBlockKeys.type => BulletedListBlockKeys.type,
      NumberedListBlockKeys.type => NumberedListBlockKeys.type,
      TodoListBlockKeys.type => TodoListBlockKeys.type,
      QuoteBlockKeys.type => QuoteBlockKeys.type,
      csesCodeBlockType => csesCodeBlockType,
      ImageBlockKeys.type => ImageBlockKeys.type,
      csesLinkBlockType => csesLinkBlockType,
      csesVideoBlockType => csesVideoBlockType,
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

  /// 从借用 [node] 读取文字、href链接和单字符公式/提及投影，拆开同属性合并的原子。
  /// 普通字符不继承公式身份；未知 AppFlowy 属性由其他适配边界处理。
  static List<CollabEditorTextSegment> _readNodeSegments(Node node) {
    final delta = node.delta;
    if (delta == null) {
      return const [];
    }
    final segments = delta
        .whereType<TextInsert>()
        .expand((operation) {
          if (operation.attributes?[collabInlineLatexAttribute] is! String &&
              operation.attributes?[collabInlineMentionAttribute] is! String) {
            return [operation];
          }
          return operation.text.runes.map(
            (rune) => TextInsert(
              String.fromCharCode(rune),
              attributes: {
                ...?operation.attributes,
                if (rune != 0xfffc) collabInlineLatexAttribute: null,
                if (rune != 0xfffc) collabInlineMentionAttribute: null,
                if (rune != 0xfffc) collabMentionIdAttribute: null,
                if (rune != 0xfffc) collabMentionTypeAttribute: null,
                if (rune != 0xfffc) collabMentionAttributesAttribute: null,
              },
            ),
          );
        })
        .map((operation) {
          final attributes = operation.attributes ?? const <String, Object>{};
          return CollabEditorTextSegment(
            text: operation.text,
            typography: attributes.keys.any((key) => collabTypographyKeys.contains(key) && attributes[key] != null)
                ? jsonEncode({
                    for (final key in collabTypographyKeys.toList()..sort())
                      if (attributes[key] != null) key: attributes[key],
                  })
                : null,
            href: attributes[AppFlowyRichTextKeys.href] as String?,
            inlineLatex: operation.attributes?[collabInlineLatexAttribute] as String?,
            inlineMention: attributes[collabInlineMentionAttribute] as String?,
            mentionId: attributes[collabMentionIdAttribute] as String?,
            mentionType: attributes[collabMentionTypeAttribute] as String?,
            mentionAttributes: attributes[collabMentionAttributesAttribute] as String?,
            bold: attributes[AppFlowyRichTextKeys.bold] == true,
            italic: attributes[AppFlowyRichTextKeys.italic] == true,
            underline: attributes[AppFlowyRichTextKeys.underline] == true,
            strikethrough: attributes[AppFlowyRichTextKeys.strikethrough] == true,
            code: attributes[AppFlowyRichTextKeys.code] == true,
            textColor: attributes[AppFlowyRichTextKeys.textColor] is String
                ? attributes[AppFlowyRichTextKeys.textColor] as String
                : null,
            backgroundColor: attributes[AppFlowyRichTextKeys.backgroundColor] is String
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
    return const {'left', 'center', 'right', 'justify', 'distributed'}.contains(value) ? value as String : 'left';
  }

  static bool _supportsIndent(String blockType) =>
      blockType == BulletedListBlockKeys.type ||
      blockType == NumberedListBlockKeys.type ||
      blockType == TodoListBlockKeys.type;

  /// 读取借用[node]的正文或资源地址，容器、分割线、分页符、公式、会议、KR和任务卡片不提供文字。
  static String _readNodePlainText(Node node) {
    if (isCollabContainerType(node.type) ||
        node.type == collabDividerType ||
        node.type == collabPageDividerType ||
        node.type == collabFormulaType ||
        node.type == collabMeetingType ||
        (node.type == collabTaskCardType || node.type == collabKrType)) {
      return "";
    }
    // Media/embed nodes intentionally have no Delta. Their URL is serialized
    // through `CollabBlock.text` so Rust/Yrs can preserve and synchronize it
    // with the same mature per-block Y.Text mechanism as ordinary content.
    if (node.type == ImageBlockKeys.type) {
      return node.attributes[ImageBlockKeys.url] as String? ?? '';
    }
    if (isCollabResourceType(node.type) || node.type == csesLinkBlockType || node.type == csesVideoBlockType) {
      return node.attributes[csesEmbedUrlAttribute] as String? ?? '';
    }
    final delta = node.delta;
    if (delta != null) {
      return delta.toPlainText();
    }
    return node.children.map(_readNodePlainText).join('\n');
  }

  static bool _blocksEqual(List<CollabEditorBlock> left, List<CollabEditorBlock> right) {
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
    blockType == csesVideoBlockType;

bool _segmentsEqual(List<CollabEditorTextSegment> left, List<CollabEditorTextSegment> right) {
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
