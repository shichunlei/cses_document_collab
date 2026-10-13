import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';

const collabResourceTypes = {
  'attachment',
  'audio',
  'bookmark',
  'embed',
  'juejin-embed',
  'figma-embed',
};
const collabResourceAttribute = 'cses_resource';
const collabResourceTargetAttribute = 'cses_resource_target';
const collabResourceKindAttribute = 'cses_resource_kind';
const collabResourceKeys = {
  'name',
  'type',
  'size',
  'icon',
  'sourceType',
  'title',
  'description',
  'image',
  'wr',
  'ar',
  'width',
  'height',
};
String resourcePropertyAttribute(String key) => 'cses_resource_$key';

bool isCollabResourceType(String type) => collabResourceTypes.contains(type);

bool isCollabResourceUrl(String kind, String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      value.length > 8192 ||
      value.contains(RegExp(r'\s'))) {
    return false;
  }
  if (kind == 'figma-embed') {
    return {'figma.com', 'www.figma.com', 'embed.figma.com'}.contains(uri.host);
  }
  if (kind == 'juejin-embed') {
    return {'juejin.cn', 'www.juejin.cn'}.contains(uri.host);
  }
  return true;
}

/// Whitelisted display props plus an explicit, field-only mutation intent.
final class CollabResource {
  const CollabResource({this.properties = '{}', this.propertyEdits});
  final String properties;
  final String? propertyEdits;
  Map<String, dynamic> get values =>
      Map<String, dynamic>.from(jsonDecode(properties) as Map);
  String string(String key) =>
      values[key] is String ? values[key] as String : '';
  double? number(String key) =>
      values[key] is num ? (values[key] as num).toDouble() : null;
  factory CollabResource.fromValues(
    Map<String, dynamic> values, {
    String? edits,
  }) => CollabResource(
    properties: jsonEncode({
      for (final key in values.keys.toList()..sort()) key: values[key],
    }),
    propertyEdits: edits,
  );
  factory CollabResource.fromJson(Map<String, dynamic> values) =>
      CollabResource(properties: values['properties'] as String? ?? '{}');
  Map<String, dynamic> toJson() => {'properties': properties};
  String field(String key) =>
      jsonEncode(values.containsKey(key) ? {'value': values[key]} : {});
  Map<String, dynamic> get nodeAttributes => {
    collabResourceAttribute: toJson(),
    for (final key in collabResourceKeys)
      resourcePropertyAttribute(key): field(key),
  };
  factory CollabResource.fromAttributes(
    Map<String, dynamic> attributes, {
    Set<String> edited = const {},
  }) {
    final base = attributes[collabResourceAttribute];
    final resource = base is Map
        ? CollabResource.fromJson(Map<String, dynamic>.from(base))
        : const CollabResource();
    final values = resource.values;
    final edits = <String, dynamic>{};
    for (final key in collabResourceKeys) {
      final field = attributes[resourcePropertyAttribute(key)];
      if (field is! String) continue;
      final wrapper = jsonDecode(field) as Map;
      if (wrapper.containsKey('value')) {
        values[key] = wrapper['value'];
      } else {
        values.remove(key);
      }
      if (edited.contains(key)) edits[key] = wrapper;
    }
    if (edited.contains('url')) edits['url'] = {'value': attributes['url']};
    return CollabResource.fromValues(
      values,
      edits: edits.isEmpty ? null : jsonEncode(edits),
    );
  }
  @override
  bool operator ==(Object other) =>
      other is CollabResource &&
      other.properties == properties &&
      other.propertyEdits == propertyEdits;
  @override
  int get hashCode => Object.hash(properties, propertyEdits);
}

/// Edits one property, preserving other fields and resolving undo by stable identity.
Future<bool> changeCollabResourceProperty(
  EditorState state,
  String id,
  String property,
  Object? value,
) async {
  if (state.isDisposed ||
      !state.editable ||
      (property != 'url' && !collabResourceKeys.contains(property))) {
    return false;
  }
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id &&
        isCollabResourceType(node.type)) {
      return node;
    }
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  final node = visit(state.document.root);
  if (node == null) return false;
  if (property == 'url' &&
      (value is! String || !isCollabResourceUrl(node.type, value))) {
    return false;
  }
  final key = property == 'url' ? 'url' : resourcePropertyAttribute(property);
  final next = property == 'url'
      ? value
      : jsonEncode(value == null ? {} : {'value': value});
  if (node.attributes[key] == next) return false;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    state.transaction..add(
      UpdateOperation(
        node.path,
        {
          key: next,
          collabResourceTargetAttribute: id,
          collabResourceKindAttribute: node.type,
        },
        {
          key: node.attributes[key],
          collabResourceTargetAttribute: id,
          collabResourceKindAttribute: node.type,
        },
      ),
    ),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}
