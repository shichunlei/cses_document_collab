import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/text_delta.dart' as collab;

typedef LocalEditorBlocksChanged =
    void Function(List<CollabEditorBlock> blocks);

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

/// Product default shown only when a document has no cover block at all.
///
/// An existing cover block whose URL is empty means the user deliberately
/// removed the image; header normalization therefore never reapplies this URL
/// to an existing block.
const csesDefaultDocumentCoverUrl =
    'https://gips0.baidu.com/it/u=4248708052,2809939788&fm=3028&app=3028&f=JPEG&fmt=auto?w=1280&h=720';

/// Shared node attribute used by the custom link and video renderers.
///
/// The collaborative wire model deliberately reuses `CollabBlock.text` for
/// this value. That keeps URL-backed blocks compatible with the existing Yrs
/// text storage while the AppFlowy document exposes a renderer-friendly
/// attribute instead of an artificial editable Delta.
const csesEmbedUrlAttribute = 'url';
const csesBlockIndentAttribute = 'cses_collab_indent';
const csesSuperscriptAttribute = 'cses_superscript';
const csesSubscriptAttribute = 'cses_subscript';

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

final class CollabEditorBlock {
  const CollabEditorBlock({
    required this.id,
    required this.blockType,
    required this.text,
    this.segments = const [],
    this.checked = false,
    this.alignment = 'left',
    this.indent = 0,
  });

  final String id;
  final String blockType;
  final String text;
  final List<CollabEditorTextSegment> segments;
  final bool checked;
  final String alignment;
  final int indent;

  @override
  int get hashCode => Object.hash(
    id,
    blockType,
    text,
    Object.hashAll(segments),
    checked,
    alignment,
    indent,
  );

  @override
  bool operator ==(Object other) {
    return other is CollabEditorBlock &&
        other.id == id &&
        other.blockType == blockType &&
        other.text == text &&
        _segmentsEqual(other.segments, segments) &&
        other.checked == checked &&
        other.alignment == alignment &&
        other.indent == indent;
  }

  @override
  String toString() =>
      'CollabEditorBlock($id, $blockType, $text, $segments, $checked, '
      '$alignment, $indent)';
}

/// Maps AppFlowy top-level nodes to the mobile block-level Yrs schema.
///
/// AppFlowy owns rendering, selection, IME and local undo. Rust/Yrs owns block
/// order, block type metadata and a separate collaborative Y.Text per block.
/// Supported inline Delta attributes are stored as native Y.Text formatting.
final class AppFlowyBlockEditorAdapter {
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

  List<CollabEditorBlock> get blocks =>
      _readBlocks(editorState, _lastPublishedBlocks);
  String get text => blocks.map((block) => block.text).join('\n');

  /// Applies canonical Rust/Yrs blocks without publishing them as local edits.
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

    final currentNodes = editorState.document.root.children;
    // URL-backed blocks do not own a Delta, so replacing them must use the
    // structural branch below. This also ensures a changed remote URL reaches
    // native image/video controllers instead of being treated as text input.
    final canPatchInPlace =
        currentNodes.length == targetBlocks.length &&
        List<bool>.generate(
          currentNodes.length,
          (index) =>
              _nodeBlockId(currentNodes[index]) == targetBlocks[index].id &&
              _nodeBlockType(currentNodes[index]) ==
                  targetBlocks[index].blockType &&
              currentNodes[index].delta != null,
        ).every((matches) => matches);
    final transaction = editorState.transaction;

    if (canPatchInPlace) {
      for (var index = 0; index < currentNodes.length; index += 1) {
        final node = currentNodes[index];
        final target = targetBlocks[index];
        final currentSegments = _readNodeSegments(node);
        if (!_segmentsEqual(currentSegments, target.segments)) {
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
        if (node.attributes[blockComponentAlign] != target.alignment ||
            node.attributes[csesBlockIndentAttribute] != targetIndent) {
          transaction.updateNode(node, {
            blockComponentAlign: target.alignment,
            csesBlockIndentAttribute: targetIndent,
          });
        }
      }
    } else {
      if (currentNodes.isNotEmpty) {
        transaction.deleteNodesAtPath([0], currentNodes.length);
      }
      transaction.add(
        InsertOperation([
          0,
        ], targetBlocks.map(_nodeFromBlock).toList(growable: false)),
        transform: false,
      );
    }

    if (transaction.operations.isEmpty) {
      _lastPublishedBlocks = targetBlocks;
      return;
    }
    _applyingRemote = true;
    try {
      await editorState.apply(
        transaction,
        isRemote: true,
        options: const ApplyOptions(recordUndo: false, inMemoryUpdate: true),
      );
      _lastPublishedBlocks = targetBlocks;
    } finally {
      _applyingRemote = false;
    }
  }

  void _handleTransaction(EditorTransactionValue value) {
    if (_disposed || _applyingRemote || value.$1 != TransactionTime.after) {
      return;
    }
    final nextBlocks = blocks;
    if (_blocksEqual(nextBlocks, _lastPublishedBlocks)) {
      return;
    }
    _lastPublishedBlocks = List<CollabEditorBlock>.unmodifiable(nextBlocks);
    onLocalBlocksChanged(_lastPublishedBlocks);
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
        : blocks.map(_nodeFromBlock).toList(growable: false);
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

  static Node _nodeFromBlock(CollabEditorBlock block) {
    if (_isUrlBackedBlock(block.blockType)) {
      final isImage = block.blockType == ImageBlockKeys.type;
      return Node(
        type: block.blockType,
        id: block.id,
        attributes: {
          // AppFlowy's image component and the custom embed components both
          // currently use `url`; spelling out the key choice documents which
          // renderer owns the attribute and avoids coupling future formats.
          if (isImage) ImageBlockKeys.url: block.text,
          if (!isImage) csesEmbedUrlAttribute: block.text,
          if (isImage) ImageBlockKeys.align: block.alignment,
          collabBlockIdAttribute: block.id,
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
        <String, Object>{blockComponentBackgroundColor: '0xfff3f4f6'},
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
        blockComponentAlign: block.alignment,
        csesBlockIndentAttribute: _supportsIndent(block.blockType)
            ? block.indent
            : 0,
        ...extraAttributes,
      },
    );
  }

  static List<CollabEditorBlock> _readBlocks(
    EditorState state,
    List<CollabEditorBlock> previous,
  ) {
    final nodes = state.document.root.children;
    final explicitIds = nodes
        .map((node) => node.attributes[collabBlockIdAttribute])
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet();
    final seenIds = <String>{};
    return List<CollabEditorBlock>.generate(nodes.length, (index) {
      final node = nodes[index];
      var blockId = _nodeBlockId(node);
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
      seenIds.add(blockId);
      if (attributeValue != blockId) {
        node.updateAttributes({collabBlockIdAttribute: blockId});
      }
      return CollabEditorBlock(
        id: blockId,
        blockType: _nodeBlockType(node),
        text: _readNodePlainText(node),
        segments: _readNodeSegments(node),
        checked:
            node.type == TodoListBlockKeys.type &&
            (node.attributes[TodoListBlockKeys.checked] as bool? ?? false),
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

  static String _nodeBlockId(Node node) {
    final value = node.attributes[collabBlockIdAttribute];
    return value is String && value.isNotEmpty ? value : node.id;
  }

  static String _nodeBlockType(Node node) {
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
    return value == 'center' || value == 'right' ? value as String : 'left';
  }

  static bool _supportsIndent(String blockType) =>
      blockType == BulletedListBlockKeys.type ||
      blockType == NumberedListBlockKeys.type ||
      blockType == TodoListBlockKeys.type;

  static String _readNodePlainText(Node node) {
    // Media/embed nodes intentionally have no Delta. Their URL is serialized
    // through `CollabBlock.text` so Rust/Yrs can preserve and synchronize it
    // with the same mature per-block Y.Text mechanism as ordinary content.
    if (node.type == ImageBlockKeys.type) {
      return node.attributes[ImageBlockKeys.url] as String? ?? '';
    }
    if (node.type == csesLinkBlockType ||
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
