import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'dart:convert';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_code_editing.dart';
import 'package:cses_document_collab/src/editor/core/document_editor_controller.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/editor/core/editor_configuration.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:flutter/services.dart';

/// 拥有内存块正文与输入监听的本地会话，不创建协同控制器、SQLite或块锁。
/// 业务端口只接受显式注入，借用资源由调用方持有。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final controller = LocalEditorController(initialText: '本地正文');
/// // 包内视图卸载后释放会话。
/// await controller.close();
/// ```
final class LocalEditorController extends DocumentEditorController {
  /// [initialText] 是初始纯文本，CRLF规范化为LF；[configuration]为空使用本地预设。
  /// [services]为空时使用空业务端口；显式注入时由调用方持有，不由本会话释放。
  /// 配置在会话期间不可替换；拒绝协同预设，不创建或启用块锁。
  /// 创建者应在视图卸载后等待close；不再单独dispose借用的editorState。
  LocalEditorController({
    String initialText = '',
    EditorConfiguration? configuration,
    CollabHostServices? services,
  }) : super(
         document: _document(
           initialText,
           configuration ?? EditorConfiguration.local,
         ),
       ) {
    final config = configuration ?? EditorConfiguration.local;
    editorState.transactionGuard = _allows;
    EditorCommandContext.bind(
      editorState,
      EditorCommandContext(
        configuration: config,
        services: services,
        localOnly: true,
        pastePlainText: pasteFromClipboard,
      ),
    );
  }

  /// 按[configuration]验证[initialText]并创建纯文本树，非法输入在分配编辑器前拒绝。
  static Document _document(
    String initialText,
    EditorConfiguration configuration,
  ) {
    if (configuration.documentFeatures) throw ArgumentError('本地编辑不能使用协同能力预设');
    final text = initialText.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.replaceAll('\n', '').replaceAll('\r', '').length >
            configuration.maxCharacters ||
        text.split('\n').length > configuration.maxBlocks ||
        text.contains('\uFFFC')) {
      throw ArgumentError('正文超过配置容量或包含嵌入对象');
    }
    return Document(
      root: Node(
        type: 'page',
        children: [
          for (final line in text.split('\n')) paragraphNode(text: line),
        ],
      ),
    );
  }

  /// 此会话冻结的功能配置，由命令、菜单和事务校验共同读取。
  EditorConfiguration get configuration => commandContext.configuration;

  /// 在提交前按实例配置检查借用的[transaction]；容量、类型或锁元数据不合法时整批拒绝。
  bool _allows(Transaction transaction) {
    if (closed) return false;
    if (configuration.usesRichDocument) return _allowsRich(transaction);
    var count = editorState.document.root.children.length;
    var length = editorState.document.root.children.fold<int>(
      0,
      (sum, n) => sum + (n.delta?.length ?? 0),
    );
    for (final op in transaction.operations) {
      if (op.path.length != 1) return false;
      if (op is InsertOperation) {
        count += op.nodes.length;
        for (final n in op.nodes) {
          if (!configuration.allowsBlock(
                n.type,
                level: n.attributes[HeadingBlockKeys.level] == null
                    ? null
                    : n.attributes[HeadingBlockKeys.level] is int
                    ? n.attributes[HeadingBlockKeys.level] as int
                    : -1,
              ) ||
              n.children.isNotEmpty ||
              n.delta == null ||
              !_allowsAttributes(n.attributes) ||
              !_validDelta(n.delta!)) {
            return false;
          }
          length += n.delta!.length;
        }
      } else if (op is DeleteOperation) {
        count -= op.nodes.length;
        length -= op.nodes.fold<int>(
          0,
          (sum, n) => sum + (n.delta?.length ?? 0),
        );
      } else if (op is UpdateTextOperation) {
        if (!_validDelta(op.delta)) return false;
        for (final run in op.delta) {
          if (run is TextInsert) length += run.text.length;
          if (run is TextDelete) length -= run.length;
        }
      } else if (op is UpdateOperation) {
        if (!_allowsAttributes(op.attributes)) return false;
        final delta = op.attributes[blockComponentDelta];
        if (delta != null) {
          final next = Delta.fromJson(delta);
          if (!_validDelta(next)) return false;
          length +=
              next.length -
              (editorState.getNodeAtPath(op.path)?.delta?.length ?? 0);
        }
      }
    }
    return count >= 1 &&
        count <= configuration.maxBlocks &&
        length <= configuration.maxCharacters;
  }

  /// 对[transaction]递归校验已注册块与结构子块，不访问协同或锁服务。
  /// 统计整棵正文及绘图源码，拒绝根替换、锁元数据和超出配置容量的整批操作。
  bool _allowsRich(Transaction transaction) {
    /// 统计[node]及其全部后代。
    int count(Node node) =>
        1 + node.children.fold<int>(0, (sum, child) => sum + count(child));

    /// 统计[node]子树的正文及源码UTF-16长度。
    int textLength(Node node) =>
        (node.delta?.length ?? 0) +
        node.children.fold<int>(0, (sum, child) => sum + textLength(child));

    /// 拒绝[values]中的锁元数据并检查配置约束。
    bool attributes(Map<String, dynamic> values) =>
        values.entries.every((entry) {
          final key = entry.key;
          if (key.contains('block_lock') ||
              key == 'lock' ||
              key == 'locked' ||
              key == 'templateLock') {
            return entry.value == null;
          }
          if (key == HeadingBlockKeys.level && entry.value != null) {
            return configuration.headingLevels.contains(entry.value);
          }
          if (key == blockComponentAlign && entry.value != null) {
            // left是基础排版值；禁用对齐操作不应禁止普通块的默认结构。
            return entry.value == 'left' ||
                configuration.alignments.contains(entry.value);
          }
          if (key == paragraphPropertyAttribute('textDefaults') &&
              entry.value is String) {
            final wrapper = jsonDecode(entry.value as String);
            return wrapper is Map &&
                configuration.allowsTextAttributes(
                  paragraphDefaultsToAttributes(wrapper['value']),
                );
          }
          return true;
        });

    /// 递归检查[node]的已注册类型、格式和子结构。
    bool valid(Node node) {
      final level = node.attributes[HeadingBlockKeys.level];
      return configuration.allowsBlock(
            node.type,
            level: level is int ? level : null,
          ) &&
          attributes(node.attributes) &&
          (node.delta == null || _validDelta(node.delta!)) &&
          node.children.every(valid);
    }

    try {
      final roots = editorState.document.root.children;
      var rootCount = roots.length;
      var blocks = roots.fold<int>(0, (sum, node) => sum + count(node));
      var characters = roots.fold<int>(
        0,
        (sum, node) => sum + textLength(node),
      );
      for (final operation in transaction.operations) {
        if (operation.path.isEmpty) return false;
        if (operation is InsertOperation) {
          if (operation.path.length == 1) rootCount += operation.nodes.length;
          for (final node in operation.nodes) {
            if (!valid(node)) return false;
            blocks += count(node);
            characters += textLength(node);
          }
        } else if (operation is DeleteOperation) {
          if (operation.path.length == 1) rootCount -= operation.nodes.length;
          for (final node in operation.nodes) {
            blocks -= count(node);
            characters -= textLength(node);
          }
        } else if (operation is UpdateTextOperation) {
          if (!_validDelta(operation.delta)) return false;
          for (final run in operation.delta) {
            if (run is TextInsert) characters += run.text.length;
            if (run is TextDelete) characters -= run.length;
          }
        } else if (operation is UpdateOperation) {
          if (!attributes(operation.attributes)) return false;
          final value = operation.attributes[blockComponentDelta];
          if (value != null) {
            final next = Delta.fromJson(value);
            if (!_validDelta(next)) return false;
            characters +=
                next.length -
                (editorState.getNodeAtPath(operation.path)?.delta?.length ?? 0);
          }
        }
      }
      return rootCount > 0 &&
          blocks <= configuration.maxBlocks &&
          characters <= configuration.maxCharacters;
    } on FormatException {
      return false;
    }
  }

  /// 校验[attributes]中的块、默认格式及布局属性；保留输入所需的稳定节点身份，不接受锁或嵌入属性。
  bool _allowsAttributes(Map<String, dynamic> attributes) {
    try {
      for (final entry in attributes.entries) {
        final key = entry.key;
        final value = entry.value;
        if (value == null) continue;
        if (key == blockComponentDelta ||
            key == collabParagraphTargetAttribute ||
            key == 'cses_collab_block_id') {
          continue;
        }
        if (key == HeadingBlockKeys.level) {
          if (!configuration.headingLevels.contains(value)) {
            return false;
          }
        } else if (key == blockComponentAlign) {
          if (value != 'left' && !configuration.alignments.contains(value)) {
            return false;
          }
        } else if (key == TodoListBlockKeys.checked) {
          if (value != null && value is! bool) return false;
        } else if (key == 'cses_collab_indent') {
          if (value != null && value != 0) return false;
        } else if (key.startsWith('cses_paragraph_')) {
          if (value == null) continue;
          if (value is! String) return false;
          final wrapper = jsonDecode(value);
          if (wrapper is! Map) return false;
          final setting = wrapper['value'];
          if (setting == null) continue;
          if (key == paragraphPropertyAttribute('textDefaults')) {
            if (setting is! Map ||
                !configuration.allowsTextAttributes(
                  paragraphDefaultsToAttributes(setting),
                )) {
              return false;
            }
          } else if (key == paragraphPropertyAttribute('heading')) {
            if (!configuration.allowsBlock(
              'heading',
              level: setting is int ? setting : -1,
            )) {
              return false;
            }
          } else if (key == paragraphPropertyAttribute('nextParagraphStyle')) {
            if (!configuration.nextParagraphStyle ||
                !const {'same', 'body'}.contains(setting)) {
              return false;
            }
          } else if (key == paragraphPropertyAttribute('lh')) {
            if (!configuration.lineHeight ||
                setting is! num ||
                !setting.isFinite ||
                setting < 1 ||
                setting > 3) {
              return false;
            }
          } else if (key == paragraphPropertyAttribute('depth')) {
            if (setting != 0) return false;
          } else {
            return false;
          }
        } else {
          return false;
        }
      }
      return true;
    } on FormatException {
      return false;
    }
  }

  /// 借用的 [delta] 只接受普通文本；拒绝对象占位以避免静默丢失语义。
  bool _validDelta(Delta delta) => delta.every((run) {
    if (run is TextInsert) {
      return (!run.text.contains('\uFFFC') ||
              (run.text == '\uFFFC' &&
                  ((run.attributes?['cses_inline_latex'] is String &&
                          configuration.allowsFormat('cses_inline_latex')) ||
                      (run.attributes?['cses_inline_mention'] is String &&
                          configuration.allowsFormat(
                            'cses_inline_mention',
                          ))))) &&
          configuration.allowsTextAttributes(run.attributes ?? {});
    }
    if (run is TextRetain) {
      return configuration.allowsTextAttributes(run.attributes ?? {});
    }
    return true;
  });

  /// 对当前范围应用 [attributes]；空光标只设置后续输入，空段落保留默认格式。
  /// 每次显式操作独立撤销，Future在编辑器事务完成后结束。
  Future<void> format(Attributes attributes) async {
    if (closed ||
        editorState.selection == null ||
        !configuration.allowsTextAttributes(attributes)) {
      return;
    }
    _sealHistory();
    if (editorState.selection!.isCollapsed) {
      await setCollabTypingAttributes(editorState, attributes);
    } else {
      await formatCollabParagraphSelection(
        editorState,
        editorState.selection!,
        attributes,
      );
    }
    _sealHistory();
  }

  /// 将当前文字叶子范围转换为启用的[type]；[level]仅用于heading，必须属于配置级别。
  /// 支持段落、标题、引用、三种列表及代码间转换，保留正文和字符格式并独立撤销。
  /// 容器、资源、含子节点或混合范围整批忽略，保持内容、选区和历史；结构块使用专用插入命令。
  Future<void> convert(String type, {int level = 1}) async {
    if (closed ||
        !_convertibleTextTypes.contains(type) ||
        !configuration.allowsBlock(type, level: level)) {
      return;
    }
    final selection = editorState.selection;
    if (selection == null) return;
    final nodes = editorState.getNodesInSelection(selection);
    if (nodes.isEmpty ||
        nodes.any(
          (node) =>
              !_convertibleTextTypes.contains(node.type) ||
              node.delta == null ||
              node.children.isNotEmpty,
        )) {
      return;
    }
    _sealHistory();
    final transaction = editorState.transaction;
    for (final node in nodes.reversed) {
      final replacement = Node(
        type: type,
        attributes: {
          ...node.attributes,
          HeadingBlockKeys.level: type == 'heading' ? level : null,
          if (type == 'todo_list') TodoListBlockKeys.checked: false,
        },
      );
      transaction.add(DeleteOperation(node.path, [node]), transform: false);
      transaction.add(
        InsertOperation(node.path, [replacement]),
        transform: false,
      );
    }
    transaction.afterSelection = selection;
    await editorState.apply(transaction, skipHistoryDebounce: true);
  }

  /// 无需容器结构或资源属性的文字转换集合；能力配置仍决定各实例是否启用。
  static const _convertibleTextTypes = {
    'paragraph',
    'heading',
    'quote',
    'bulleted_list',
    'numbered_list',
    'todo_list',
    'code',
  };

  /// 为当前段落范围设置 [alignment] 和可选 [lineHeight]；null表示不修改对应字段。
  /// 对齐允许left/center/right/justify，行高倍率允许1～3。
  Future<void> layout({String? alignment, double? lineHeight}) async {
    if (closed || editorState.selection == null) return;
    if (alignment != null && !configuration.alignments.contains(alignment)) {
      throw ArgumentError('无效对齐');
    }
    if (lineHeight != null &&
        (!configuration.lineHeight ||
            !lineHeight.isFinite ||
            lineHeight < 1 ||
            lineHeight > 3)) {
      throw ArgumentError('无效行高');
    }
    _sealHistory();
    final transaction = editorState.transaction;
    for (final node in editorState.getNodesInSelection(
      editorState.selection!,
    )) {
      transaction.updateNode(node, {
        blockComponentAlign: ?alignment,
        if (lineHeight != null)
          paragraphPropertyAttribute('lh'): jsonEncode({'value': lineHeight}),
      });
    }
    transaction.afterSelection = editorState.selection;
    await editorState.apply(transaction, skipHistoryDebounce: true);
  }

  /// 固定当前历史边界，避免显式格式命令与前后输入合并。
  void _sealHistory() {
    if (editorState.undoManager.undoStack.isNonEmpty) {
      editorState.undoManager.undoStack.last.seal();
    }
  }

  /// 复制当前选中文字；[cut] 为true时仅在系统写入成功、正文和选区未变后剪切。
  /// 等待期间来源变化则抛出StateError并保留正文，不持有宿主剪贴板服务。
  Future<void> copyText({bool cut = false}) async {
    if (closed) return;
    final selection = editorState.selection?.normalized;
    if (selection == null || selection.isCollapsed) return;
    final capturedRevision = revision;
    final originalSelection = editorState.selection;
    final nodes = editorState.getNodesInSelection(selection);
    if (nodes.any((node) => node.delta == null)) return;
    final text = <String>[];
    for (final node in nodes) {
      final start = node.path.equals(selection.start.path)
          ? selection.start.offset
          : 0;
      final end = node.path.equals(selection.end.path)
          ? selection.end.offset
          : node.delta!.length;
      text.add(node.delta!.slice(start, end).toPlainText());
    }
    await Clipboard.setData(ClipboardData(text: text.join('\n')));
    if (!cut || closed) return;
    if (revision != capturedRevision ||
        editorState.selection != originalSelection) {
      throw StateError('正文或选区已变化，请重新剪切');
    }
    await pasteText('');
  }

  /// 读取系统纯文本，来源版本和选区仍有效时原子粘贴；异步失败交给当前页面。
  Future<void> pasteFromClipboard() async {
    if (closed) return;
    final selection = editorState.selection;
    final capturedRevision = revision;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (closed || selection == null) return;
    if (revision != capturedRevision || editorState.selection != selection) {
      throw StateError('正文或选区已变化，请重新粘贴');
    }
    if (data?.text != null) await pasteText(data!.text!);
  }

  /// 选中当前全部正文，不修改内容或历史。
  void selectAll() {
    if (closed) return;
    final nodes = editorState.document.root.children;
    editorState.selection = Selection(
      start: Position(path: [0]),
      end: Position(
        path: [nodes.length - 1],
        offset: nodes.last.delta?.length ?? 1,
      ),
    );
  }

  /// 在当前同级文字叶子选区原子粘贴[text]，不解析Markdown、HTML或链接。
  /// 单代码块保留换行、身份及属性；其他文字按换行生成正文，保留范围外内容和格式。
  /// 容器及跨父范围不执行；超过配置容量或功能范围时在删除前拒绝并抛出StateError。
  Future<void> pasteText(String text) async {
    if (closed || editorState.selection == null) return;
    if (text.replaceAll('\n', '').replaceAll('\r', '').length >
        configuration.maxCharacters) {
      throw StateError('粘贴内容超过${configuration.maxCharacters}字符');
    }
    final selection = editorState.selection!.normalized;
    final nodes = editorState.getNodesInSelection(selection.normalized);
    if (nodes.isEmpty ||
        nodes.any(
          (n) =>
              n.delta == null ||
              n.children.isNotEmpty ||
              n.parent != nodes.first.parent,
        )) {
      return;
    }
    if (text.contains('\uFFFC')) {
      throw StateError('不支持嵌入对象');
    }
    final normalizedText = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (nodes.length == 1 && nodes.first.type == 'code') {
      final transaction = buildCollabCodeTextReplacement(
        editorState,
        selection,
        normalizedText,
      );
      if (transaction == null) return;
      if (!_allows(transaction)) throw StateError('粘贴后的内容不符合当前编辑能力或容量限制');
      _sealHistory();
      await editorState.apply(transaction, skipHistoryDebounce: true);
      return;
    }
    final lines = normalizedText.split('\n');
    if (lines.length > configuration.maxBlocks) {
      throw StateError('粘贴内容超过${configuration.maxBlocks}段');
    }
    final first = nodes.first;
    final prefix = first.delta!.slice(0, selection.start.offset);
    final suffix = nodes.last.delta!.slice(selection.end.offset);
    final attributes = collabParagraphTypingAttributes(
      first,
      selection.start.offset,
      pending: editorState.toggledStyle,
    );
    final inserted = <Node>[];
    for (var i = 0; i < lines.length; i++) {
      final delta = Delta();
      if (i == 0) delta.addAll(prefix);
      delta.insert(lines[i], attributes: attributes);
      if (i == lines.length - 1) delta.addAll(suffix);
      inserted.add(
        Node(
          type: i == 0 ? first.type : ParagraphBlockKeys.type,
          attributes: {
            ...first.attributes,
            blockComponentDelta: delta.toJson(),
          },
        ),
      );
    }
    final transaction = editorState.transaction;
    transaction.add(DeleteOperation(first.path, nodes), transform: false);
    transaction.add(InsertOperation(first.path, inserted), transform: false);
    transaction.afterSelection = Selection.collapsed(
      Position(
        path: [...first.path.parent, first.path.last + lines.length - 1],
        offset: lines.last.length + (lines.length == 1 ? prefix.length : 0),
      ),
    );
    if (!_allows(transaction)) throw StateError('粘贴后的内容不符合当前编辑能力或容量限制');
    _sealHistory();
    await editorState.apply(transaction, skipHistoryDebounce: true);
  }
}
