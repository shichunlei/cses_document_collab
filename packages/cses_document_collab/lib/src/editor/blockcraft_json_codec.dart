import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/editor_text_attributes.dart';
import 'package:cses_document_collab/src/editor/blockcraft_snapshot_presets.g.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_kr.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:cses_document_collab/src/model/collab_mermaid.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:cses_document_collab/src/model/collab_task_card.dart';

/// 将桌面快照转换为实际编辑树；每块/行内对象均转换，不保存原始JSON快照兜底。
/// props/meta分别成为独立本地属性，未知插件类型直接报错，不生成占位块。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final document = BlockCraftJsonCodec.decode({
///   'id':'root', 'flavour':'root', 'nodeType':'root',
///   'props':{}, 'meta':{}, 'children':[],
/// });
/// final editor = DocumentEditorController(document: document);
/// final json = BlockCraftJsonCodec.encode(editor.editorState.document);
/// await editor.close();
/// ```
abstract final class BlockCraftJsonCodec {
  /// 单次导入/导出允许的UTF-8字节数，4MiB。
  static const byteLimit = 4 * 1024 * 1024;

  /// 已显式转换的桌面类型；新插件必须增加转换和渲染规则后方可接收。
  static const flavours = {
    'root',
    'paragraph',
    'bullet',
    'ordered',
    'todo',
    'blockquote',
    'code',
    'callout',
    'image',
    'video',
    'caption',
    'divider',
    'page-divider',
    'formula',
    'mermaid',
    'mermaid-textarea',
    'table',
    'table-row',
    'table-cell',
    'columns',
    'column',
    'attachment',
    'audio',
    'bookmark',
    'embed',
    'figma-embed',
    'juejin-embed',
    'shape',
    'shape-text',
    'word-art',
    'text-box',
    'object-group',
    'placement-layout',
    'render-unit',
    'task',
    'task-list',
    'meeting',
    'kr-list',
    'weather',
    'date-card',
    'person-card',
    'sticker',
    'mind-map',
  };

  /// 需使用新增原生对象/容器渲染器的桌面类型。
  static const objectFlavours = {
    'columns',
    'column',
    'shape',
    'text-box',
    'object-group',
    'placement-layout',
    'render-unit',
    'task-list',
    'weather',
    'date-card',
    'person-card',
    'sticker',
    'mind-map',
  };

  /// 桌面无正文叶块；新建原生节点导出时同样使用void协议。
  static const voidFlavours = {
    'attachment',
    'audio',
    'video',
    'bookmark',
    'embed',
    'figma-embed',
    'juejin-embed',
    'divider',
    'page-divider',
    'formula',
    'task',
    'task-list',
    'meeting',
    'kr-list',
    'weather',
    'date-card',
    'person-card',
    'sticker',
    'mind-map',
  };

  /// 桌面的可编辑文本叶块；children必须为插入项，不允许当作结构容器读取。
  static const editableFlavours = {
    'paragraph',
    'ordered',
    'bullet',
    'todo',
    'blockquote',
    'code',
    'caption',
    'mermaid-textarea',
    'shape-text',
    'word-art',
  };

  /// 本地字符键到桌面字符键的映射；其他桌面字符键作为独立属性转换。
  static const textKeys = {
    'bold': 'a:bold',
    'italic': 'a:italic',
    'underline': 'a:underline',
    'strikethrough': 'a:strike',
    'code': 'a:code',
    'font_color': 's:color',
    'bg_color': 's:background',
    'href': 'a:link',
    'cses_superscript': 'a:sup',
    'cses_subscript': 'a:sub',
  };

  /// 返回[node]对应的桌面flavour，新建本地文字节点根据当前类型推导。
  static String flavour(Node node) => switch (node.type) {
    'paragraph' when {'caption', 'shape-text', 'word-art'}.contains(node.attributes['bc.flavour']) =>
      node.attributes['bc.flavour'] as String,
    'paragraph' => 'paragraph',
    'page' => 'root',
    'heading' => 'paragraph',
    'bulleted_list' => 'bullet',
    'numbered_list' => 'ordered',
    'todo_list' => 'todo',
    'quote' => 'blockquote',
    _ when node.type.startsWith('snapshot-') =>
      node.attributes['bc.flavour'] as String? ?? node.type.substring('snapshot-'.length),
    _ => node.type,
  };

  /// 返回[node]的已转换独立属性，不含原始块JSON；[metadata]默认false，true读取meta。
  static Map<String, dynamic> properties(Node node, {bool metadata = false}) {
    final prefix = metadata ? 'bc.m:' : 'bc.p:';
    return {
      for (final entry in node.attributes.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value is Map && (entry.value as Map).containsKey('v')
              ? (entry.value as Map)['v']
              : entry.value,
    };
  }

  /// 将[snapshot]校验并转换为调用方拥有的文档；失败抛FormatException，不创建网络或原生资源。
  static Document decode(Map<String, dynamic> snapshot) {
    validate(snapshot);
    return Document(root: decodeBlock(snapshot));
  }

  /// 编码借用的[document]，返回不共享可变引用的独立根快照；调用者仍负责释放文档。
  static Map<String, dynamic> encode(Document document) {
    final result = encodeBlock(document.root);
    validate(result);
    return _copy(result);
  }

  /// 校验[snapshot]的容量、唯一身份、类型及完整Delta；[root]默认true，false校验单块子树。
  /// 拒绝未知flavour及畸形结构，不静默删除不支持数据。
  static void validate(Map<String, dynamic> snapshot, {bool root = true}) {
    if (utf8.encode(jsonEncode(snapshot)).length > byteLimit) {
      throw const FormatException('文档JSON不能超过4MiB');
    }
    if (root && (snapshot['flavour'] != 'root' || snapshot['nodeType'] != 'root')) {
      throw const FormatException('请选择包含root根块的桌面JSON');
    }
    final ids = <String>{};
    var count = 0;

    /// 遍历[block]并用[depth]约束递归；块上限5000、深度上限64。
    void visit(Map block, int depth) {
      final id = block['id'];
      if (++count > 5000 ||
          depth > 64 ||
          id is! String ||
          id.isEmpty ||
          id.length > 256 ||
          !ids.add(id) ||
          !flavours.contains(block['flavour']) ||
          block['props'] is! Map ||
          block['meta'] is! Map ||
          block['children'] is! List) {
        throw FormatException('桌面块结构、身份或类型无效：${block['flavour']}');
      }
      final children = block['children'] as List;
      final expected = block['flavour'] == 'root'
          ? 'root'
          : voidFlavours.contains(block['flavour'])
          ? 'void'
          : editableFlavours.contains(block['flavour'])
          ? 'editable'
          : 'block';
      if (block['nodeType'] != expected) throw const FormatException('桌面块类型与nodeType不匹配');
      final props = block['props'] as Map;
      if (block['flavour'] == 'shape' &&
          props['customGeometry'] == null &&
          !snapshotShapePaths.containsKey(props['shape'] ?? 'rectangle')) {
        throw const FormatException('文档含未注册的形状预设');
      }
      if (block['flavour'] == 'sticker' && !snapshotStickerPresets.containsKey(props['presetId'])) {
        throw const FormatException('文档含未注册的贴纸预设');
      }
      switch (block['nodeType']) {
        case 'root':
        case 'block':
          if (depth > 0 && block['nodeType'] == 'root') throw const FormatException('根块不能嵌套');
          for (final child in children) {
            if (child is! Map) throw const FormatException('桌面子块无效');
            visit(child, depth + 1);
          }
        case 'editable':
          for (final run in children) {
            if (run is! Map ||
                !run.containsKey('insert') ||
                run.containsKey('retain') ||
                run.containsKey('delete') ||
                (run['insert'] is! String && run['insert'] is! Map) ||
                (run['attributes'] != null && run['attributes'] is! Map)) {
              throw const FormatException('桌面富文本快照无效');
            }
            final inserted = run['insert'];
            if (inserted is Map) {
              if (inserted.length != 1 ||
                  !{
                    'mention',
                    'latex',
                    'image',
                    'date',
                    'shape',
                    'word-art',
                    'sticker',
                    'weather',
                    'person',
                  }.contains(inserted.keys.single)) {
                throw const FormatException('文档含未注册的行内对象');
              }
              if (inserted.containsKey('mention')) {
                final attrs = run['attributes'] as Map? ?? {};
                final id = attrs['mentionId'] ?? attrs['d:mentionId'];
                if (id is! String || id.trim().isEmpty) throw const FormatException('人员或实体提及缺少身份');
              }
            }
          }
        case 'void':
          if (children.isNotEmpty) throw const FormatException('空块含子内容');
        default:
          throw const FormatException('桌面nodeType无效');
      }
    }

    visit(snapshot, 0);
  }

  /// 转换已校验的[block]及其后代为实际原生节点；返回节点的所有权交给调用者。
  static Node decodeBlock(Map<String, dynamic> block) {
    final kind = block['flavour'] as String;
    final id = block['id'] as String;
    final props = Map<String, dynamic>.from(block['props'] as Map);
    final metadata = Map<String, dynamic>.from(block['meta'] as Map);
    final nodeType = block['nodeType'] as String;
    final delta = nodeType == 'editable' ? decodeInline(block['children'] as List) : Delta();
    final mobileType = switch (kind) {
      'root' => 'page',
      'paragraph' => props['heading'] is num && props['heading'] > 0 ? 'heading_${props['heading']}' : 'paragraph',
      'bullet' => 'bulleted_list',
      'ordered' => 'numbered_list',
      'todo' => 'todo_list',
      'blockquote' => 'quote',
      'caption' || 'shape-text' || 'word-art' => 'paragraph',
      _ => kind,
    };
    final projection = CollabEditorBlock(
      id: id,
      blockType: mobileType,
      text: nodeType == 'editable' ? delta.toPlainText() : '${props[kind == 'image' ? 'src' : 'url'] ?? ''}',
      checked: props['checked'] == 1 || props['checked'] == true,
      alignment: '${props['textAlign'] ?? props['align'] ?? 'left'}',
      indent: props['depth'] is num ? (props['depth'] as num).toInt() : 0,
      paragraphStyle: CollabResource.fromValues({
        for (final key in collabParagraphKeys)
          if (props.containsKey(key)) key: props[key],
      }),
      code: kind == 'code' ? CollabCode.fromProperties(props) : null,
      image: kind == 'image' ? CollabImage.fromJson(props) : null,
      ordered: kind == 'ordered'
          ? CollabOrdered(
              order: (props['order'] as num?)?.toInt() ?? 0,
              markerStyle: props['ms'] as String?,
              numbering: jsonEncode({
                for (final key in ['start', 'continuePrevious'])
                  if (props.containsKey(key)) key: props[key],
              }),
            )
          : null,
      resource: CollabResource.fromValues(props),
      calloutPrefix: props['prefix'] as String?,
      blockTextColor: props['color'] as String?,
      blockBackgroundColor: props['backColor'] as String?,
      blockBorderColor: props['borderColor'] as String?,
    );
    final Node node;
    if (kind == 'root' || objectFlavours.contains(kind)) {
      node = Node(type: kind == 'root' ? 'page' : 'snapshot-$kind', id: id);
    } else {
      node = createCollabSnapshotNode(projection);
      if (nodeType == 'editable') node.updateAttributes({'delta': delta.toJson()});
    }
    node.updateAttributes({
      'bc.id': id,
      'bc.flavour': kind,
      'bc.nodeType': nodeType,
      for (final entry in props.entries) 'bc.p:${entry.key}': {'v': entry.value},
      for (final entry in metadata.entries) 'bc.m:${entry.key}': {'v': entry.value},
      for (final entry in block.entries)
        if (!{'id', 'flavour', 'nodeType', 'props', 'meta', 'children'}.contains(entry.key))
          'bc.x:${entry.key}': entry.value,
    });
    if (nodeType == 'block' || nodeType == 'root') {
      for (final child in block['children'] as List) {
        node.insert(decodeBlock(Map<String, dynamic>.from(child as Map)));
      }
    }
    return node;
  }

  /// 将借用的[node]及后代重新编码；内容读取实时编辑树，不回放旧快照或编辑历史。
  /// 文字叶块带真实子块时抛FormatException，不输出遗漏后代的快照；宿主可在事务预检调用。
  static Map<String, dynamic> encodeBlock(Node node) {
    final kind = flavour(node);
    if (node.delta != null && node.children.isNotEmpty) {
      throw const FormatException('桌面文字叶块不能包含真实子块，请使用平面缩进');
    }
    final props = properties(node);
    final original = node.attributes['bc.flavour'];
    if (kind != original) {
      if (kind != 'todo') {
        props
          ..remove('checked')
          ..remove('created');
      }
      if (kind != 'ordered') {
        for (final key in ['order', 'start', 'continuePrevious', 'ms']) {
          props.remove(key);
        }
      }
    }
    if (node.delta != null) {
      if (kind == 'paragraph') {
        if (node.type == 'heading') {
          props['heading'] = node.attributes['level'];
        } else {
          props.remove('heading');
        }
      }
      if (kind == 'todo') props['checked'] = node.attributes['checked'] == true ? 1 : 0;
      if (node.attributes.containsKey('align')) {
        if (node.attributes['align'] == 'left') {
          props.remove('textAlign');
        } else {
          props['textAlign'] = node.attributes['align'];
        }
      }
      for (final key in collabParagraphKeys) {
        if (key == 'heading') continue;
        final value = node.attributes[paragraphPropertyAttribute(key)];
        if (value is String) {
          final wrapper = jsonDecode(value) as Map;
          if (wrapper.containsKey('value')) {
            props[key] = wrapper['value'];
          } else {
            props.remove(key);
          }
        }
      }
      if (node.attributes['cses_collab_indent'] is num &&
          !node.attributes.containsKey(paragraphPropertyAttribute('depth'))) {
        props['depth'] = node.attributes['cses_collab_indent'];
      }
      if (kind == 'code') {
        props.addAll(jsonDecode(CollabCode.fromAttributes(node.attributes).properties) as Map<String, dynamic>);
      }
      if (kind == 'ordered' && node.attributes[csesOrderedNumberingAttribute] is String) {
        props
          ..remove('start')
          ..remove('continuePrevious');
        props.addAll(
          Map<String, dynamic>.from(jsonDecode(node.attributes[csesOrderedNumberingAttribute] as String) as Map),
        );
      }
    }
    if (kind == 'image') {
      props['src'] = node.attributes['url'] ?? '';
      if (node.attributes['align'] != null && node.attributes['align'] != 'left') {
        props['align'] = node.attributes['align'];
      }
      final image = node.attributes[collabImageAttribute];
      if (image is Map) {
        for (final key in ['wr', 'ar', 'width', 'height', 'rotation']) {
          if (image[key] != null) {
            props[key] = image[key];
          } else {
            props.remove(key);
          }
        }
      }
    }
    if (kind == csesCalloutBlockType) {
      for (final entry in const {
        'prefix': csesCalloutPrefixAttribute,
        'color': csesBlockTextColorAttribute,
        'backColor': csesBlockBackgroundColorAttribute,
        'borderColor': csesBlockBorderColorAttribute,
      }.entries) {
        final value = node.attributes[entry.value];
        if (value == null) {
          props.remove(entry.key);
        } else {
          props[entry.key] = value;
        }
      }
    }
    if (kind == collabTaskCardType || kind == collabKrType) {
      props
        ..clear()
        ..addAll(
          kind == collabTaskCardType
              ? CollabTaskCard.read(node.attributes).values
              : readCollabKr(node.attributes).values,
        );
    }
    if ({'video', ...collabResourceTypes}.contains(kind)) {
      props.addAll(CollabResource.fromAttributes(node.attributes).values);
      props['url'] = node.attributes['url'] ?? props['url'];
    }
    if (kind == 'formula') props.addAll(readCollabFormula(node.attributes).values);
    if (kind == 'mermaid') props.addAll(readCollabMermaidProperties(node.attributes).values);
    if (kind == 'meeting') props.addAll(CollabMeeting.readAttributes(node.attributes).values);
    if (kind == 'divider') props.addAll(CollabDivider.readAttributes(node.attributes).values);
    if (collabTableTypes.contains(kind)) props.addAll(collabTableLayout(node));
    final nodeType = voidFlavours.contains(kind)
        ? 'void'
        : node.delta != null
        ? 'editable'
        : kind == 'root'
        ? 'root'
        : (original == kind ? node.attributes['bc.nodeType'] as String? : null) ?? 'block';
    return {
      for (final entry in node.attributes.entries)
        if (entry.key.startsWith('bc.x:')) entry.key.substring(5): entry.value,
      'id': node.attributes['bc.id'] ?? node.id,
      'flavour': kind,
      'nodeType': nodeType,
      'props': props,
      'meta': properties(node, metadata: true),
      'children': node.delta != null ? encodeInline(node.delta!) : node.children.map(encodeBlock).toList(),
    };
  }

  /// 将桌面插入项[runs]转为原生Delta；每个行内对象占一个U+FFFC，未知对象也转换为独立属性。
  static Delta decodeInline(List runs) {
    final result = Delta();
    final inverse = {for (final entry in textKeys.entries) entry.value: entry.key};
    for (final item in runs) {
      final run = item as Map;
      final attrs = <String, dynamic>{};
      final inserted = run['insert'];
      for (final entry in (run['attributes'] as Map? ?? {}).entries) {
        final key = '${entry.key}';
        if (inserted is Map && inserted.containsKey('mention') && !RegExp(r'^[ast]:').hasMatch(key)) continue;
        attrs[inverse[key] ?? (collabTypographyKeys.contains(key) ? key : 'bc.a:$key')] = entry.value;
      }
      if (inserted is String) {
        result.insert(inserted, attributes: attrs.isEmpty ? null : attrs);
      } else {
        final object = inserted as Map;
        if (object['mention'] is String) {
          final raw = Map<String, dynamic>.from(run['attributes'] as Map? ?? {});
          attrs.addAll({
            'cses_inline_mention': object['mention'],
            'cses_mention_id': raw['mentionId'] ?? raw['d:mentionId'],
            if ((raw['mentionType'] ?? raw['d:mentionType'] ?? 'user') != 'user')
              'cses_mention_type': raw['mentionType'] ?? raw['d:mentionType'],
            'cses_mention_attributes': jsonEncode(raw),
          });
        } else if (object['latex'] is String) {
          attrs['cses_inline_latex'] = object['latex'];
        } else {
          for (final entry in object.entries) {
            final value = entry.value;
            if (value is String && value.trimLeft().startsWith('{')) {
              attrs['bc.e:${entry.key}'] = jsonDecode(value);
              attrs['bc.f:${entry.key}'] = 'json';
            } else {
              attrs['bc.e:${entry.key}'] = value;
            }
          }
        }
        result.insert('\uFFFC', attributes: attrs);
      }
      registerEditorTextAttributes(
        attrs.keys.where((key) => key.startsWith('bc.a:') || key.startsWith('bc.e:') || key.startsWith('bc.f:')),
      );
    }
    return result;
  }

  /// 将借用的[delta]转为桌面插入项；拒绝无身份U+FFFC，不自动推断普通@文本的人员身份。
  static List<Map<String, dynamic>> encodeInline(Delta delta) {
    final result = <Map<String, dynamic>>[];
    for (final operation in delta.whereType<TextInsert>()) {
      final source = operation.attributes ?? {};
      final attrs = <String, dynamic>{};
      for (final entry in source.entries) {
        final key = entry.key;
        if (textKeys.containsKey(key) || collabTypographyKeys.contains(key) || key.startsWith('bc.a:')) {
          final target = textKeys[key] ?? (key.startsWith('bc.a:') ? key.substring(5) : key);
          attrs[target] = {'s:color', 's:background'}.contains(target) ? cssColor(entry.value) : entry.value;
        }
      }
      if (!operation.text.contains('\uFFFC')) {
        result.add({'insert': operation.text, if (attrs.isNotEmpty) 'attributes': attrs});
        continue;
      }
      for (final rune in operation.text.runes) {
        if (rune != 0xfffc) {
          result.add({
            'insert': String.fromCharCode(rune),
            if (attrs.isNotEmpty) 'attributes': {...attrs},
          });
          continue;
        }
        final object = <String, dynamic>{};
        final objectAttrs = {...attrs};
        if (source['cses_inline_mention'] is String) {
          final raw = source['cses_mention_attributes'];
          if (raw is String) {
            final identity = Map<String, dynamic>.from(jsonDecode(raw) as Map);
            identity.removeWhere((key, _) => RegExp(r'^[ast]:').hasMatch(key));
            objectAttrs.addAll(identity);
          }
          objectAttrs.addAll(attrs);
          objectAttrs['mentionId'] = source['cses_mention_id'];
          objectAttrs['mentionType'] = source['cses_mention_type'] ?? 'user';
          objectAttrs.remove('d:mentionId');
          objectAttrs.remove('d:mentionType');
          object['mention'] = source['cses_inline_mention'];
        } else if (source['cses_inline_latex'] is String) {
          object['latex'] = source['cses_inline_latex'];
        } else {
          for (final entry in source.entries) {
            if (entry.key.startsWith('bc.e:')) {
              object[entry.key.substring(5)] = source['bc.f:${entry.key.substring(5)}'] == 'json'
                  ? jsonEncode(entry.value)
                  : entry.value;
            }
          }
        }
        if (object.isEmpty) throw const FormatException('行内对象缺少可转换的身份');
        result.add({'insert': object, if (objectAttrs.isNotEmpty) 'attributes': objectAttrs});
      }
    }
    return result;
  }

  /// 将[value]中的移动ARGB颜色转换为CSS，已有CSS/null原样返回，透明度不丢失。
  static Object? cssColor(Object? value) {
    if (value is! String || !RegExp(r'^0x[0-9a-fA-F]{8}$').hasMatch(value)) return value;
    final argb = int.parse(value.substring(2), radix: 16);
    final alpha = argb >> 24;
    return alpha == 255
        ? '#${(argb & 0xffffff).toRadixString(16).padLeft(6, '0')}'
        : 'rgba(${(argb >> 16) & 255}, ${(argb >> 8) & 255}, ${argb & 255}, ${alpha / 255})';
  }

  /// 深拷贝借用[value]，避免编码结果继续引用可编辑属性。
  static Map<String, dynamic> _copy(Map value) => Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
}
