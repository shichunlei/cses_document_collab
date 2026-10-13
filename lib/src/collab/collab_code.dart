import 'dart:convert';

const collabCodeAttribute = 'cses_blockcraft_code';
const collabCodeTargetAttribute = 'cses_code_target';
const collabCodePropertyAttributes = {
  'lang': 'cses_code_lang',
  'blockName': 'cses_code_name',
  'collapse': 'cses_code_collapse',
};

/// Header values plus original props for field-specific undo and explicit edits.
final class CollabCode {
  const CollabCode({
    this.language = 'PlainText',
    this.name = '',
    this.collapsed = false,
    this.rawProperties,
    this.propertyEdits,
  });

  final String language;
  final String name;
  final bool collapsed;
  final String? rawProperties;

  /// Only explicit local property transactions carry a patch to Rust.
  final String? propertyEdits;

  String get properties {
    final values = rawProperties == null
        ? <String, dynamic>{
            'lang': language,
            if (name.isNotEmpty) 'blockName': name,
            if (collapsed) 'collapse': true,
          }
        : Map<String, dynamic>.from(jsonDecode(rawProperties!) as Map);
    return jsonEncode({
      for (final key in values.keys.toList()..sort()) key: values[key],
    });
  }

  factory CollabCode.fromProperties(
    Map<String, dynamic> values, {
    String? propertyEdits,
  }) => CollabCode(
    language: values['lang'] is String ? values['lang'] as String : 'PlainText',
    name: values['blockName'] is String ? values['blockName'] as String : '',
    collapsed: values['collapse'] == true,
    rawProperties: jsonEncode(values),
    propertyEdits: propertyEdits,
  );

  factory CollabCode.fromJson(Map<String, dynamic> json) => CollabCode(
    language: json['language'] as String? ?? 'PlainText',
    name: json['name'] as String? ?? '',
    collapsed: json['collapsed'] == true,
    rawProperties: json['properties'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'language': language,
    'name': name,
    'collapsed': collapsed,
    'properties': properties,
  };

  /// A wrapper distinguishes an absent native prop from an explicit null.
  String propertyAttribute(String property) {
    final values = jsonDecode(properties) as Map;
    return jsonEncode(
      values.containsKey(property) ? {'value': values[property]} : {},
    );
  }

  Map<String, String> get nodeAttributes => {
    for (final entry in collabCodePropertyAttributes.entries)
      entry.value: propertyAttribute(entry.key),
  };

  factory CollabCode.fromAttributes(
    Map<String, dynamic> attributes, {
    Set<String> editedProperties = const {},
  }) {
    final raw = attributes[collabCodeAttribute];
    final base = raw is Map
        ? CollabCode.fromJson(Map<String, dynamic>.from(raw))
        : const CollabCode();
    final values = Map<String, dynamic>.from(
      jsonDecode(base.properties) as Map,
    );
    final edits = <String, dynamic>{};
    for (final entry in collabCodePropertyAttributes.entries) {
      final encoded = attributes[entry.value];
      if (encoded is! String) continue;
      final wrapper = jsonDecode(encoded) as Map;
      if (wrapper.containsKey('value')) {
        values[entry.key] = wrapper['value'];
      } else {
        values.remove(entry.key);
      }
      if (editedProperties.contains(entry.key)) edits[entry.key] = wrapper;
    }
    return CollabCode.fromProperties(
      values,
      propertyEdits: edits.isEmpty ? null : jsonEncode(edits),
    );
  }

  @override
  int get hashCode =>
      Object.hash(language, name, collapsed, properties, propertyEdits);

  @override
  bool operator ==(Object other) =>
      other is CollabCode &&
      other.language == language &&
      other.name == name &&
      other.collapsed == collapsed &&
      other.properties == properties &&
      other.propertyEdits == propertyEdits;
}
