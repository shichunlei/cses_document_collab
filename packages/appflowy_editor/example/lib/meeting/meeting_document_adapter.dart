import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';

/// Converts the meeting description tree used by CSES to an editable document.
///
/// The original node is retained in each editor block so untouched blocks keep
/// their IDs, metadata, optional fields, and exact text-run boundaries. Editor
/// changes are projected back onto that tree when [export] is called.
class MeetingDocumentAdapter {
  /// Creates the stateless meeting document converter.
  const MeetingDocumentAdapter();

  static const _sourceKey = '_csesMeetingSource';
  static const _initialDeltaKey = '_csesMeetingInitialDelta';
  static int _nextDemoId = 0;

  /// Creates a protocol-backed editor block of [flavour] with [props].
  ///
  /// Text blocks start with an empty editable run. A callout starts with one
  /// editable paragraph so its body can be changed directly in the editor.
  /// The returned node is detached and may be inserted by an editor transaction.
  Node createBlock(String flavour, {Map<String, dynamic> props = const {}}) {
    final protocolFlavour = flavour == 'heading' ? 'paragraph' : flavour;
    final source = _newNode(protocolFlavour, _newDemoId());
    final blockProps = _asMap(_copy(props));
    if (flavour == 'heading') blockProps.putIfAbsent('heading', () => 1);
    if (flavour == 'todo') blockProps.putIfAbsent('checked', () => 0);
    if (flavour == 'ordered') blockProps.putIfAbsent('order', () => 0);
    source['props'] = blockProps;
    if (source['nodeType'] == 'editable') {
      source['children'] = <Map<String, dynamic>>[
        {'insert': ''},
      ];
    } else if (flavour == 'callout') {
      final child = _newNode('paragraph', _newDemoId());
      child['children'] = <Map<String, dynamic>>[
        {'insert': ''},
      ];
      source['children'] = <Map<String, dynamic>>[child];
    }
    return _importNode(source);
  }

  /// Returns a detached copy of [node]'s meeting-specific block properties.
  Map<String, dynamic> propsOf(Node node) {
    final source = node.attributes[_sourceKey];
    if (source is! Map) return <String, dynamic>{};
    return _asMap(_copy(_asMap(source)['props'] ?? <String, dynamic>{}));
  }

  /// Returns attributes for an editor transaction that updates [node] to [props].
  ///
  /// The source tree and AppFlowy's image fields are updated together. Other
  /// meeting-only blocks render and export from their retained source props.
  Attributes updatedBlockAttributes(Node node, Map<String, dynamic> props) {
    final sourceValue = node.attributes[_sourceKey];
    final source = sourceValue is Map
        ? _asMap(_copy(sourceValue))
        : _newNode(_flavourForType(node.type), node.id);
    source['props'] = _asMap(_copy(props));
    return {
      _sourceKey: source,
      if (node.type == 'image') ...{
        'url': props['src'],
        'width': (props['width'] as num?)?.toDouble(),
        'height': (props['height'] as num?)?.toDouble(),
      },
    };
  }

  /// Imports [description], which must be a root node with a children array.
  Document import(Map<String, dynamic> description) {
    if (description['flavour'] != 'root' || description['children'] is! List) {
      throw const FormatException('Meeting description must be a root tree');
    }
    return Document(
      root: Node(
        type: 'page',
        id: description['id'] as String?,
        attributes: {_sourceKey: _copy(description)},
        // Node's constructor iterates children twice to link parent pointers.
        // Materialize once so both passes use the same child instances.
        children: (description['children'] as List)
            .map((child) => _importNode(_asMap(child)))
            .toList(),
      ),
    );
  }

  /// Exports [document] as a meeting description tree, retaining source data.
  ///
  /// Blocks created inside AppFlowy receive an ID and timestamps at export.
  /// The caller owns [document] and must dispose its editor state separately.
  Map<String, dynamic> export(Document document) {
    final source = document.root.attributes[_sourceKey];
    final root = source is Map
        ? _asMap(_copy(source))
        : _newNode('root', document.root.id);
    root['children'] = document.root.children.map(_exportNode).toList();
    return root;
  }

  Node _importNode(Map<String, dynamic> source) {
    final flavour = source['flavour'] as String? ?? 'paragraph';
    final props = _asMap(source['props'] ?? <String, dynamic>{});
    final hasText = source['nodeType'] == 'editable';
    final delta = hasText
        ? _importDelta(source['children'] as List? ?? const [])
        : null;
    final type = switch (flavour) {
      'paragraph' when props['heading'] is int => 'heading',
      'ordered' => 'numbered_list',
      'bullet' => 'bulleted_list',
      'todo' => 'todo_list',
      'blockquote' => 'quote',
      'figma-embed' => 'cses_figma_embed',
      'juejin-embed' => 'cses_juejin_embed',
      'callout' => 'cses_callout',
      'audio' => 'cses_audio',
      'video' => 'cses_video',
      'bookmark' => 'cses_bookmark',
      'attachment' => 'cses_attachment',
      _ => flavour,
    };
    return Node(
      type: type,
      id: source['id'] as String?,
      attributes: {
        _sourceKey: _copy(source),
        if (delta != null) ...{
          'delta': delta.toJson(),
          _initialDeltaKey: jsonEncode(delta.toJson()),
        },
        if (type == 'heading') 'level': props['heading'],
        if (type == 'numbered_list')
          'number': (props['order'] as int? ?? 0) + 1,
        if (type == 'todo_list') 'checked': props['checked'] == 1,
        if (type == 'code') 'language': props['lang'],
        if (hasText && props['textAlign'] is String)
          blockComponentAlign: props['textAlign'],
        if (type == 'image') ...{
          'url': props['src'],
          'width': (props['width'] as num?)?.toDouble(),
          'height': (props['height'] as num?)?.toDouble(),
          'align': 'center',
        },
      },
      children: hasText
          ? const []
          : (source['children'] as List? ?? const [])
                .map((child) => _importNode(_asMap(child)))
                .toList(),
    );
  }

  Map<String, dynamic> _exportNode(Node node) {
    final sourceValue = node.attributes[_sourceKey];
    final source = sourceValue is Map
        ? _asMap(_copy(sourceValue))
        : _newNode(_flavourForType(node.type), node.id);
    final originalType = _editorTypeForSource(source);
    final typeChanged = sourceValue is Map && originalType != node.type;
    final props = typeChanged
        ? <String, dynamic>{}
        : _asMap(source['props'] ?? <String, dynamic>{});
    if (typeChanged) {
      source['flavour'] = _flavourForType(node.type);
      source['nodeType'] = _isTextType(node.type) ? 'editable' : 'void';
    }

    if (_isTextType(node.type)) {
      final delta = node.delta ?? (Delta()..insert(''));
      final initial = node.attributes[_initialDeltaKey];
      final textUnchanged = initial == jsonEncode(delta.toJson());
      final alignment = node.attributes[blockComponentAlign];
      final propsUnchanged = switch (node.type) {
        'heading' =>
          props['heading'] == node.attributes['level'] &&
              props['textAlign'] == alignment,
        'numbered_list' =>
          props['order'] == ((node.attributes['number'] as int?) ?? 1) - 1 &&
              props['textAlign'] == alignment,
        'todo_list' =>
          (props['checked'] == 1) == (node.attributes['checked'] == true) &&
              props['textAlign'] == alignment,
        'code' =>
          props['lang'] == node.attributes['language'] &&
              props['textAlign'] == alignment,
        _ => props['textAlign'] == alignment,
      };
      if (sourceValue is Map &&
          !typeChanged &&
          textUnchanged &&
          propsUnchanged) {
        return source;
      }
      if (node.type == 'heading') props['heading'] = node.attributes['level'];
      if (node.type == 'numbered_list') {
        props['order'] = ((node.attributes['number'] as int?) ?? 1) - 1;
      }
      if (node.type == 'todo_list') {
        props['checked'] = node.attributes['checked'] == true ? 1 : 0;
      }
      if (node.type == 'code') props['lang'] = node.attributes['language'];
      if (alignment is String) props['textAlign'] = alignment;
      source['props'] = props;
      if (!textUnchanged || typeChanged || sourceValue is! Map) {
        final runs = delta
            .whereType<TextInsert>()
            .map(
              (insert) => <String, dynamic>{
                'insert': insert.text,
                if (insert.attributes case final attributes?)
                  if (attributes.isNotEmpty)
                    'attributes': _exportAttributes(attributes),
              },
            )
            .toList();
        source['children'] = runs.isEmpty
            ? <Map<String, dynamic>>[
                {'insert': ''},
              ]
            : runs;
      }
    } else {
      if (node.type == 'image') {
        props['src'] = node.attributes['url'];
        final width = node.attributes['width'];
        final height = node.attributes['height'];
        if (width is num) props['width'] = width.toInt();
        if (height is num) props['height'] = height.toInt();
        source['props'] = props;
      }
      source['children'] = node.children.map(_exportNode).toList();
    }
    return source;
  }

  Delta _importDelta(List<dynamic> children) {
    final delta = Delta();
    for (final item in children) {
      final run = _asMap(item);
      final insert = run['insert'];
      if (insert is! String) continue;
      final sourceAttributes = run['attributes'];
      delta.insert(
        insert,
        attributes: sourceAttributes is Map
            ? _importAttributes(_asMap(sourceAttributes))
            : null,
      );
    }
    if (delta.isEmpty) delta.insert('');
    return delta;
  }

  Map<String, dynamic> _importAttributes(Map<String, dynamic> source) {
    const mapping = {
      'a:bold': 'bold',
      'a:italic': 'italic',
      'a:underline': 'underline',
      'a:strike': 'strikethrough',
      'a:code': 'code',
      'a:link': 'href',
    };
    return {
      for (final entry in source.entries)
        mapping[entry.key] ?? 'cses:${entry.key}': entry.value,
    };
  }

  Map<String, dynamic> _exportAttributes(Map<String, dynamic> editor) {
    const mapping = {
      'bold': 'a:bold',
      'italic': 'a:italic',
      'underline': 'a:underline',
      'strikethrough': 'a:strike',
      'code': 'a:code',
      'href': 'a:link',
    };
    return {
      for (final entry in editor.entries)
        mapping[entry.key] ??
                (entry.key.startsWith('cses:')
                    ? entry.key.substring(5)
                    : 'a:${entry.key}'):
            entry.value,
    };
  }

  String _editorTypeForSource(Map<String, dynamic> source) {
    final flavour = source['flavour'] as String? ?? 'paragraph';
    if (flavour == 'paragraph' &&
        _asMap(source['props'] ?? <String, dynamic>{})['heading'] is int) {
      return 'heading';
    }
    return switch (flavour) {
      'ordered' => 'numbered_list',
      'bullet' => 'bulleted_list',
      'todo' => 'todo_list',
      'blockquote' => 'quote',
      'figma-embed' => 'cses_figma_embed',
      'juejin-embed' => 'cses_juejin_embed',
      'callout' => 'cses_callout',
      'audio' => 'cses_audio',
      'video' => 'cses_video',
      'bookmark' => 'cses_bookmark',
      'attachment' => 'cses_attachment',
      _ => flavour,
    };
  }

  String _flavourForType(String type) => switch (type) {
    'heading' => 'paragraph',
    'numbered_list' => 'ordered',
    'bulleted_list' => 'bullet',
    'todo_list' => 'todo',
    'quote' => 'blockquote',
    'cses_figma_embed' => 'figma-embed',
    'cses_juejin_embed' => 'juejin-embed',
    'cses_callout' => 'callout',
    'cses_audio' => 'audio',
    'cses_video' => 'video',
    'cses_bookmark' => 'bookmark',
    'cses_attachment' => 'attachment',
    _ => type,
  };

  bool _isTextType(String type) => const {
    'paragraph',
    'heading',
    'numbered_list',
    'bulleted_list',
    'todo_list',
    'quote',
    'code',
  }.contains(type);

  Map<String, dynamic> _newNode(String flavour, String id) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      'id': id,
      'flavour': flavour,
      'nodeType': flavour == 'root'
          ? 'root'
          : _isTextType(_editorTypeForSource({'flavour': flavour}))
          ? 'editable'
          : const {'image', 'callout'}.contains(flavour)
          ? 'block'
          : 'void',
      'props': <String, dynamic>{},
      'meta': {
        'createdTime': now,
        'lastModified': {'time': now},
      },
      'children': <dynamic>[],
    };
  }

  /// Generates IDs only for new demo blocks; imported IDs remain unchanged.
  String _newDemoId() =>
      'demo-${DateTime.now().microsecondsSinceEpoch}-${_nextDemoId++}';

  Map<String, dynamic> _asMap(Object? value) =>
      Map<String, dynamic>.from(value as Map);

  Object _copy(Object value) => jsonDecode(jsonEncode(value)) as Object;
}
