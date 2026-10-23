import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';

import 'guidance_entries.dart';
import 'journal_draft.dart';
import 'journal_exchange_keys.dart';

/// 业务栏目与桌面根快照之间的双向转换，标准块交给通用Codec实际转换。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_blockcraft_codec.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_draft.dart';
/// final original = JournalDraft.blank(DateTime(2026, 10, 23));
/// final snapshot = JournalBlockCraftCodec.exportDraft(original);
/// final restored = JournalBlockCraftCodec.importSnapshot(snapshot);
/// print(restored.date);
/// ```
abstract final class JournalBlockCraftCodec {
  /// 将借用的[document]捕获为独立本地JSON；正文不增加ID字段，身份表独立保存。
  static Map<String, dynamic> captureDocument(Document document) =>
      Map<String, dynamic>.from(
        jsonDecode(jsonEncode(document.toJson())) as Map,
      );

  /// 捕获借用的[document]的持久身份；表按当前节点路径存储，不改变编辑树或业务属性。
  static String captureIdentities(Document document) => jsonEncode({
    for (final node in journalContentNodes([document.root]))
      node.path.join('.'): node.attributes['bc.id'] ?? node.id,
  });

  /// 把[encoded]身份表恢复到借用的[document]的运行时ID；非法路径/重复ID整次报错。
  /// 仅在视图/监听尚未装配时调用，不写正文属性或取得文档所有权。
  static void restoreIdentities(Document document, String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map || value.length > 5000) {
      throw const FormatException('文档块身份表无效');
    }
    final ids = <String>{};
    final pending = <Node, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String ||
          !RegExp(
            r'^(?:[0-9]+(?:\.[0-9]+)*)?$',
          ).hasMatch(entry.key as String) ||
          entry.value is! String ||
          (entry.value as String).isEmpty ||
          (entry.value as String).length > 256 ||
          !ids.add(entry.value as String)) {
        throw const FormatException('文档块身份表无效');
      }
      final path = (entry.key as String).isEmpty
          ? <int>[]
          : (entry.key as String).split('.').map(int.parse).toList();
      final node = document.nodeAtPath(path);
      if (node == null) throw const FormatException('文档块身份路径无效');
      pending[node] = entry.value as String;
    }
    for (final entry in pending.entries) {
      entry.key.id = entry.value;
    }
  }

  /// 将已校验的[draft]导出为独立桌面根快照；包含可见栏目及已转换的关闭栏目恢复信息。
  /// 文字/对象读取正文，不使用纯文本或HTML中转；非法或未知块抛FormatException。
  static Map<String, dynamic> exportDraft(JournalDraft draft) {
    final document = Document.fromJson(
      jsonDecode(draft.documentJson) as Map<String, dynamic>,
    );
    try {
      restoreIdentities(document, draft.blockCraftIdsJson);
      validateJournalDocument(document);
      final root = document.root;
      final plain = root.attributes[journalPlainDesktopAttribute] == true;
      final children = <Map<String, dynamic>>[];
      final sections = <Map<String, dynamic>>[];
      for (final section in root.children) {
        final key = section.attributes['section'] as String;
        sections.add({'key': key});
        if (!plain) {
          children.add({
            'id':
                section.attributes['guidance_heading_id'] ??
                'section-${section.attributes['bc.id'] ?? section.id}',
            'flavour': 'paragraph',
            'nodeType': 'editable',
            'props':
                section.attributes['guidance_heading_props'] ??
                {'heading': 2, 'depth': 0},
            'meta': {
              journalBlockCraftNamespace: {
                'version': 1,
                'role': 'section',
                'section': key,
              },
            },
            'children': section.attributes['guidance_heading_delta'] is List
                ? BlockCraftJsonCodec.encodeInline(
                    Delta.fromJson(
                      section.attributes['guidance_heading_delta'],
                    ),
                  )
                : [
                    {
                      'insert': switch (key) {
                        'record' => '今日记录',
                        'reflection' => '感悟',
                        _ => '自检',
                      },
                    },
                  ],
          });
        }
        Node? previous;
        for (final child in section.children) {
          final block = _exportBlock(child, key);
          if (child.type == 'numbered_list' &&
              previous?.type != 'numbered_list') {
            (block['props'] as Map<String, dynamic>).addAll(<String, dynamic>{
              'start': child.attributes['number'] is int
                  ? child.attributes['number']
                  : 1,
              'continuePrevious': false,
            });
          }
          children.add(block);
          previous = child;
        }
      }
      final metadata = BlockCraftJsonCodec.properties(root, metadata: true);
      metadata[journalBlockCraftNamespace] = {
        'version': 1,
        'role': 'document',
        'plainDesktop': plain,
        'draft': {
          'id': draft.id,
          'date': draft.date,
          'createdAt': draft.createdAt.toIso8601String(),
          'updatedAt': draft.updatedAt.toIso8601String(),
          'timezoneOffsetMinutes': draft.timezoneOffsetMinutes,
        },
        'sections': sections,
        'closedSections': [
          for (final section in closedJournalSections(document))
            {
              'key': section.attributes['section'],
              'children': [
                for (final child in section.children)
                  _exportBlock(child, section.attributes['section'] as String),
              ],
            },
        ],
      };
      final props = BlockCraftJsonCodec.properties(root);
      final result = {
        'id': root.attributes['bc.id'] ?? 'root-${draft.id}',
        'flavour': 'root',
        'nodeType': 'root',
        'props': props.isEmpty && !plain
            ? {'fs': 16, 'lh': 2, 'color': '#3e4650'}
            : props,
        'meta': metadata,
        'children': children,
      };
      BlockCraftJsonCodec.validate(result);
      return Map<String, dynamic>.from(jsonDecode(jsonEncode(result)) as Map);
    } finally {
      document.dispose();
    }
  }

  /// 将借用的[node]及后代转为桌面块，[section]仅提供业务栏目身份，不改变子树布局。
  static Map<String, dynamic> _exportBlock(Node node, String section) {
    // 旧人员/部门引用同样转换为结构化mention对象，不降级成@文本。
    final attributes = {...node.attributes};
    final sourceDelta = node.delta;
    if (sourceDelta != null) {
      final delta = Delta();
      for (final run in sourceDelta.whereType<TextInsert>()) {
        final format = {...?run.attributes};
        if (format.containsKey(guidanceMentionAttribute)) {
          final person = readGuidanceMention(format);
          format.remove(guidanceMentionAttribute);
          format.addAll({
            'cses_inline_mention': person.name,
            'cses_mention_id': person.id,
            'cses_mention_type': person.type,
            'cses_mention_attributes': jsonEncode({
              'mentionId': person.id,
              'mentionType': person.type,
              'd:mobileGuidanceMention': person.toJson(),
            }),
          });
        }
        delta.insert(run.text, attributes: format.isEmpty ? null : format);
      }
      attributes['delta'] = delta.toJson();
    }
    final copy = Node(type: node.type, id: node.id, attributes: attributes);
    for (final child in node.children) {
      final converted = _exportBlock(child, section);
      copy.insert(BlockCraftJsonCodec.decodeBlock(converted));
    }
    final block = BlockCraftJsonCodec.encodeBlock(copy);
    final meta = Map<String, dynamic>.from(block['meta'] as Map);
    final business = {
      for (final entry in node.attributes.entries)
        if (entry.key.startsWith('guidance_') &&
            !{
              journalDesktopImportAttribute,
              'guidance_section_revision',
              journalClosedSectionsAttribute,
            }.contains(entry.key))
          entry.key: entry.value,
    };
    final taskAsTodo =
        node.attributes[guidanceEntryAttribute] == 'task' &&
        node.type != 'todo_list';
    if (taskAsTodo) {
      block['flavour'] = 'todo';
      (block['props'] as Map)['checked'] =
          node.attributes['guidance_done'] == true ? 1 : 0;
    }
    meta[journalBlockCraftNamespace] = {
      'version': 1,
      'role': 'content',
      'section': section,
      'business': business,
      if (taskAsTodo) 'taskSourceType': node.type,
      if (taskAsTodo && node.attributes['number'] != null)
        'taskNumber': node.attributes['number'],
    };
    block['meta'] = meta;
    return block;
  }

  /// 将[snapshot]转换为可编辑的独立日记草稿；普通桌面文档默认进入今日记录。
  /// [now]用于无业务封套时的建档日期，默认当前设备时间；不会写存储或替换当前日记。
  /// 业务版本、日期或正文不合法时整次抛FormatException，调用方保留原文。
  static JournalDraft importSnapshot(
    Map<String, dynamic> snapshot, {
    DateTime? now,
  }) {
    BlockCraftJsonCodec.validate(snapshot);
    final localNow = now ?? DateTime.now();
    final metadata = Map<String, dynamic>.from(snapshot['meta'] as Map);
    final info = _extension(metadata);
    final draft = info['draft'] is Map
        ? Map<String, dynamic>.from(info['draft'] as Map)
        : null;
    final rootShell = {...snapshot, 'children': <Object>[]};
    final root = BlockCraftJsonCodec.decodeBlock(rootShell);
    root.updateAttributes({
      journalDesktopImportAttribute: true,
      journalPlainDesktopAttribute:
          info.isEmpty || info['plainDesktop'] == true,
    });
    final sectionNodes = <String, Node>{};

    /// 按[key]恢复栏目，首次出现时附到根；拒绝未知栏目或record乱序。
    Node section(String key) {
      if (!journalSections.contains(key)) {
        throw const FormatException('未知今日导向栏目');
      }
      return sectionNodes.putIfAbsent(key, () {
        final result = Node(
          type: journalSectionType,
          attributes: {'section': key},
        );
        root.insert(result);
        return result;
      });
    }

    var current = 'record';
    section(current);
    for (final value in snapshot['children'] as List) {
      final block = Map<String, dynamic>.from(value as Map);
      final ext = _extension(Map<String, dynamic>.from(block['meta'] as Map));
      if (ext['role'] == 'section') {
        current = ext['section'] as String;
        final id = block['id'] as String;
        section(current).updateAttributes({
          'bc.id': id.startsWith('section-') ? id.substring(8) : id,
          'guidance_heading_id': id,
          'guidance_heading_props': block['props'],
          'guidance_heading_delta': BlockCraftJsonCodec.decodeInline(
            block['children'] as List,
          ).toJson(),
        });
        continue;
      }
      section(current).insert(_importBlock(block));
    }
    for (final node in sectionNodes.values) {
      if (node.children.isEmpty) node.insert(paragraphNode());
    }
    final hidden = <Map<String, Object>>[];
    for (final raw in info['closedSections'] as List? ?? []) {
      final item = raw as Map;
      final key = item['key'];
      if (key is! String ||
          !journalSections.contains(key) ||
          key == 'record' ||
          sectionNodes.containsKey(key)) {
        throw const FormatException('关闭栏目恢复信息冲突');
      }
      final node = Node(type: journalSectionType, attributes: {'section': key});
      for (final block in item['children'] as List) {
        final value = Map<String, dynamic>.from(block as Map);
        BlockCraftJsonCodec.validate(value, root: false);
        node.insert(_importBlock(value));
      }
      if (node.children.isEmpty) node.insert(paragraphNode());
      hidden.add(node.toJson());
    }
    root.updateAttributes({
      if (hidden.isNotEmpty) journalClosedSectionsAttribute: hidden,
    });
    final document = Document(root: root);
    try {
      validateJournalDocument(document);
      final result = JournalDraft(
        id:
            draft?['id'] as String? ??
            'import-${localNow.microsecondsSinceEpoch}',
        date: draft?['date'] as String? ?? journalDate(localNow),
        createdAt: draft == null
            ? localNow.toUtc()
            : DateTime.parse(draft['createdAt'] as String).toUtc(),
        updatedAt: draft == null
            ? localNow.toUtc()
            : DateTime.parse(draft['updatedAt'] as String).toUtc(),
        timezoneOffsetMinutes:
            draft?['timezoneOffsetMinutes'] as int? ??
            localNow.timeZoneOffset.inMinutes,
        documentJson: jsonEncode(captureDocument(document)),
        blockCraftIdsJson: captureIdentities(document),
      );
      return JournalDraft.fromJson(result.toJson());
    } finally {
      document.dispose();
    }
  }

  /// 将[block]的业务身份附回实际转换节点；桌面修改的正文及勾选状态优先于来源显示值。
  static Node _importBlock(Map<String, dynamic> block) {
    final ext = _extension(Map<String, dynamic>.from(block['meta'] as Map));
    final node = BlockCraftJsonCodec.decodeBlock({
      ...block,
      if (block['nodeType'] == 'block') 'children': <Object>[],
    });
    final business = ext['business'] is Map
        ? Map<String, dynamic>.from(ext['business'] as Map)
        : <String, dynamic>{};
    if (business.keys.any(
      (key) =>
          !key.startsWith('guidance_') ||
          key == journalClosedSectionsAttribute ||
          key == journalDesktopImportAttribute,
    )) {
      throw const FormatException('今日导向业务属性无效');
    }
    node.updateAttributes(business);
    Node result = node;
    if (block['flavour'] == 'todo' && ext['taskSourceType'] is String) {
      final type = ext['taskSourceType'] as String;
      if (!{
        'paragraph',
        'heading',
        'bulleted_list',
        'numbered_list',
        'quote',
      }.contains(type)) {
        throw const FormatException('本地待办来源类型无效');
      }
      result = Node(
        type: type,
        id: node.id,
        attributes: {
          ...node.attributes,
          if (type == 'heading')
            'level': (block['props'] as Map)['heading'] ?? 1,
          if (type == 'numbered_list' && ext['taskNumber'] != null)
            'number': ext['taskNumber'],
          'guidance_done':
              (block['props'] as Map)['checked'] == 1 ||
              (block['props'] as Map)['checked'] == true,
        },
      );
      result.updateAttributes({
        'bc.flavour': switch (type) {
          'heading' || 'paragraph' => 'paragraph',
          'bulleted_list' => 'bullet',
          'numbered_list' => 'ordered',
          _ => 'blockquote',
        },
      });
    }
    if (block['nodeType'] == 'block') {
      for (final child in block['children'] as List) {
        result.insert(_importBlock(Map<String, dynamic>.from(child as Map)));
      }
    }
    if (result.delta != null) {
      final delta = Delta();
      for (final run in result.delta!.whereType<TextInsert>()) {
        final attrs = {...?run.attributes};
        final raw = attrs['cses_mention_attributes'];
        final mention = raw is String
            ? (jsonDecode(raw) as Map)['d:mobileGuidanceMention']
            : null;
        if (mention is Map) {
          final value = {
            ...mention,
            'id': attrs['cses_mention_id'],
            'name': attrs['cses_inline_mention'],
            'type': attrs['cses_mention_type'] ?? 'user',
          };
          for (final key in EditorUserMention.attributeKeys) {
            attrs.remove(key);
          }
          attrs.remove('bc.a:d:mobileGuidanceMention');
          attrs.remove('bc.a:mentionId');
          attrs.remove('bc.a:mentionType');
          attrs[guidanceMentionAttribute] = jsonEncode(value);
        }
        delta.insert(run.text, attributes: attrs.isEmpty ? null : attrs);
      }
      result.updateAttributes({'delta': delta.toJson()});
    }
    return result;
  }

  /// 读取借用[metadata]中的v1业务信息；不存在返回空，未来版本直接拒绝避免错误解释。
  static Map<String, dynamic> _extension(Map<String, dynamic> metadata) {
    final value = metadata[journalBlockCraftNamespace];
    if (value == null) return {};
    if (value is! Map || value['version'] != 1) {
      throw const FormatException('不支持的今日导向交换版本');
    }
    return Map<String, dynamic>.from(value);
  }
}
