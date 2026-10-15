// Yjs 13 的真实 V1 编码样本；无登录凭证、真实文档内容或线上身份。
// node generate.cjs <已安装的 yjs 包路径>；省略参数时从当前依赖解析 yjs。
const fs = require('fs');
const path = require('path');
const Y = require(process.argv[2] || 'yjs');

function block(id, flavour, nodeType, children, props = {}) {
  const b = new Y.Map();
  b.set('id', id);
  b.set('flavour', flavour);
  b.set('nodeType', nodeType);
  b.set('props', new Y.Map(Object.entries(props)));
  b.set('meta', new Y.Map([
    ['createdTime', 1791792000000],
    ['customAudit', { actor: 'fixture-author', version: 1 }],
  ]));
  const content = nodeType === 'editable' ? new Y.Text() : new Y.Array();
  if (nodeType === 'editable') content.applyDelta(children);
  else content.insert(0, children);
  b.set('children', content);
  return b;
}

function fixture(name, extra) {
  if (process.argv[3] && process.argv[3] !== name) return;
  const d = new Y.Doc({ gc: false });
  d.clientID = 123456;
  const m = d.getMap('blocks');
  m.set('fixture-doc', block('fixture-doc', 'root', 'root', ['p1', 'p2', 'todo'], { customRoot: 'preserve' }));
  m.set('p1', block('p1', 'paragraph', 'editable', [{ insert: '正文😀', attributes: {
    'a:bold': true, 'a:link': 'https://example.test', 't:ff': 'serif', 's:color': '#123456',
  } }], { depth: 0, customProp: { enabled: true }, nullable: null }));
  m.set('p2', block('p2', 'paragraph', 'editable', [{ insert: '标题' }], { depth: 0, heading: 2 }));
  m.set('todo', block('todo', 'todo', 'editable', [{ insert: '待办' }], { depth: 1, checked: 1, created: 1791792000000 }));
  d.getMap('bc:revision-meta').set('epoch', 0);
  extra?.(d, m);
  fs.writeFileSync(path.join(__dirname, name + '.update'), Y.encodeStateAsUpdate(d));
  d.destroy();
}

fixture('blockcraft-basic');
fixture('blockcraft-code', (_, m) => {
  m.get('fixture-doc').get('children').push(['code-1']);
  m.set('code-1', block('code-1', 'code', 'editable', [{
    insert: "import 'package:flutter/widgets.dart';\n\nvoid main() {\n  print('代码😀');\n}\n",
  }], {
    lang: 'Dart', blockName: '这是一段dart代码', h: 240,
    customCode: { keep: true },
  }));
});
fixture('blockcraft-unknown', (_, m) => {
  m.get('fixture-doc').get('children').push(['table']);
  m.set('table', block('table', 'table', 'block', ['cell']));
  m.set('cell', block('cell', 'paragraph', 'editable', [{ insert: '嵌套内容' }]));
});
fixture('blockcraft-embed', (_, m) => m.get('p1').get('children').insertEmbed(1, { mention: 'fixture-user' }));

// 未知未来实体只保护所在段落，嵌套对象同样保留父子边界；全为合成数据。
fixture('blockcraft-opaque-mention', (_, m) => {
  const meeting = { mentionId: 'meeting-fixture', mentionType: 'future-meeting',
    meetingId: 'meeting-fixture', number: '123456',
    status: { name: '未开始', fontColor: '#8c8c8c', backgroundColor: '#eeeeee' },
    customInline: { keep: true } };
  m.get('p1').get('children').insertEmbed(1, { mention: '会议示例' }, meeting);
  m.get('fixture-doc').get('children').push(['opaque-callout']);
  m.set('opaque-callout', block('opaque-callout', 'callout', 'block', ['opaque-child', 'editable-child']));
  m.set('opaque-child', block('opaque-child', 'paragraph', 'editable', [
    { insert: '前😀' }, { insert: { mention: '嵌套会议' }, attributes: meeting }, { insert: '后' },
  ]));
  m.set('editable-child', block('editable-child', 'paragraph', 'editable', [{ insert: '可编辑的相邻正文' }]));
});
fixture('blockcraft-locked', (_, m) => m.get('p1').get('meta').set('lock', 'fixture-owner'));

// 当前 ImageBlockSchema 使用 block + caption 子块，不能以 void 的空 children 自证兼容。
fixture('blockcraft-image', (_, m) => {
  m.get('fixture-doc').get('children').push(['image-1']);
  m.set('image-1', block('image-1', 'image', 'block', ['caption-1'], {
    src: 'https://example.test/image.png', wr: 60, ar: 1.5, align: 'right',
    rotation: 15, customImage: { keep: true },
  }));
  m.set('caption-1', block('caption-1', 'caption', 'editable', [{
    insert: '图片题注😀', attributes: { 'a:bold': true, 'a:link': 'https://example.test/caption' },
  }], { textAlign: 'center', customCaption: 42 }));
});

// 当前 OrderedBlockPlugin 的层级、标题、start 和 ms 边界；普通段落不打断同层计数。
fixture('blockcraft-ordered', (_, m) => {
  const entries = [
    ['a', 'ordered', { depth: 0, order: 0, ms: 'a2', customOrdered: { keep: true } }],
    ['gap', 'paragraph', { depth: 0 }],
    ['b', 'ordered', { depth: 0, order: 1 }],
    ['c', 'ordered', { depth: 1, order: 0, ms: 'n2' }],
    ['d', 'ordered', { depth: 1, order: 1 }],
    ['e', 'ordered', { depth: 0, order: 2 }],
    ['restart', 'ordered', { depth: 0, order: 4, start: 5, ms: null }],
    ['f', 'ordered', { depth: 0, order: 5 }],
    ['h2', 'ordered', { depth: 0, heading: 2, order: 0 }],
    ['h2-next', 'ordered', { depth: 0, heading: 2, order: 1 }],
    ['normal-after', 'ordered', { depth: 0, order: 0 }],
  ];
  const children = m.get('fixture-doc').get('children');
  children.delete(0, children.length);
  children.insert(0, entries.map(([id]) => id));
  for (const [id, flavour, props] of entries) {
    m.set(id, block(id, flavour, 'editable', [{ insert: `fixture-${id}` }], props));
  }
});

// Desktop CalloutBlockSchema: container Y.Array + independent editable Y.Text children.
fixture('blockcraft-callout', (_, m) => {
  m.get('fixture-doc').get('children').push(['callout-1']);
  m.set('callout-1', block('callout-1', 'callout', 'block', ['callout-body', 'callout-second'], {
    prefix: '🤪', backColor: '#F6E5F0', borderColor: '#FFE6CD', color: '#F97316',
    customCallout: { keep: true },
  }));
  m.set('callout-body', block('callout-body', 'paragraph', 'editable', [{
    insert: '这是高亮块儿😀', attributes: { 'a:bold': true, 'a:link': 'https://example.test/callout', 't:ff': 'serif' },
  }], { customBody: 42 }));
  m.set('callout-second', block('callout-second', 'paragraph', 'editable', [{ insert: '第二段正文' }], {}));
});

// Desktop VideoBlockSchema: url + sourceType, not image's src property.
fixture('blockcraft-video', (_, m) => {
  m.get('fixture-doc').get('children').push(['video-1', 'empty-video', 'embed-video']);
  m.set('video-1', block('video-1', 'video', 'void', [], {
    url: 'https://example.test/video.mp4', sourceType: 'link',
    poster: 'https://example.test/poster.jpg', wr: 80, customVideo: { keep: true },
  }));
  m.set('empty-video', block('empty-video', 'video', 'void', [], {
    url: '', sourceType: 'local', name: '等待上传.mp4',
  }));
  m.set('embed-video', block('embed-video', 'video', 'void', [], {
    url: '<iframe src="https://example.test/embed"></iframe>', sourceType: 'embed',
  }));
});

fixture('blockcraft-resources', (_, m) => {
  const entries = [
    ['attachment-1', 'attachment', { url: 'https://example.test/spec.pdf', name: '方案.pdf', type: 'application/pdf', size: 2048, icon: 'bc_pdf', customResource: { keep: true } }],
    ['audio-1', 'audio', { url: 'https://example.test/voice.mp3', name: '语音', sourceType: 'link', size: 4096, customResource: { keep: true } }],
    ['bookmark-1', 'bookmark', { url: 'https://example.test/article', title: '网页标题', description: '网页摘要', icon: 'https://example.test/icon.png', customResource: { keep: true } }],
    ['embed-1', 'embed', { url: 'https://example.test/page', wr: 80, ar: 1.5, customResource: { keep: true } }],
    ['juejin-1', 'juejin-embed', { url: 'https://juejin.cn/post/123456', wr: 90, ar: 1.4, customResource: { keep: true } }],
    ['figma-1', 'figma-embed', { url: 'https://www.figma.com/design/demo/Design?node-id=1-2', wr: 100, ar: 1.8, customResource: { keep: true } }],
  ];
  m.get('fixture-doc').get('children').push(entries.map(([id]) => id));
  for (const [id, kind, props] of entries) m.set(id, block(id, kind, 'void', [], props));
});

// Desktop DividerBlockSchema 0.11.14: void leaf, props only, no Y.Text or URL.
fixture('blockcraft-divider', (_, m) => {
  const styles = ['solid','dashed','dotted','double','fade','wave','zigzag','sketch','triple-dot','diamond',
    'tape-dot-black','tape-grid-pattern','tape-regular-lines','tape-gradient-blocks','tape-gray-lines',
    'edge-grass','edge-flower','edge-vine','edge-daisy','edge-stars','edge-berries'];
  const ids = styles.map((_, i) => `divider-${i}`);
  m.get('fixture-doc').get('children').push([...ids, 'legacy-divider', 'divider-callout']);
  styles.forEach((style, i) => m.set(ids[i], block(ids[i], 'divider', 'void', [], {
    style, length: 'long', thickness: 'regular', opacity: .7, lineColor: '#123456',
    customDivider: { keep: true }, text: 'legacy label preserved', align: 'right',
  })));
  m.set('legacy-divider', block('legacy-divider', 'divider', 'void', [], { size: 'small', opacity: null }));
  m.set('divider-callout', block('divider-callout', 'callout', 'block', ['nested-divider', 'nested-text']));
  m.set('nested-divider', block('nested-divider', 'divider', 'void', [], {}));
  m.set('nested-text', block('nested-text', 'paragraph', 'editable', [{insert: '嵌套后置段落'}]));
});

// FormulaBlockSchema 的 void + props.latex；包含空值、未知 TeX 与高亮容器。
fixture('blockcraft-formula', (_, m) => {
  m.get('fixture-doc').get('children').push(['formula-1', 'formula-empty', 'formula-invalid', 'formula-null', 'formula-callout']);
  m.set('formula-1', block('formula-1', 'formula', 'void', [], {
    latex: String.raw`\frac{a}{b}+\sqrt{x}`, customFormula: { keep: true },
  }));
  m.set('formula-empty', block('formula-empty', 'formula', 'void', [], {}));
  m.set('formula-invalid', block('formula-invalid', 'formula', 'void', [], { latex: String.raw`\unknowncommand{` }));
  m.set('formula-null', block('formula-null', 'formula', 'void', [], { latex: null }));
  m.set('formula-callout', block('formula-callout', 'callout', 'block', ['nested-formula'], { prefix: '💡' }));
  m.set('nested-formula', block('nested-formula', 'formula', 'void', [], { latex: 'E=mc^2' }));
});

// 行内公式占 Y.Text 一个位置，覆盖多个对象、emoji、普通 U+FFFC 与未知格式。
fixture('blockcraft-inline-formula', (_, m) => {
  const text = m.get('p1').get('children');
  text.delete(0, text.length);
  text.insert(0, '前😀', { 'a:link': 'https://example.test', customInline: 'preserve-text' });
  text.insertEmbed(text.length, { latex: String.raw`\frac{a}{b}` }, { 'a:bold': true, customInline: 'preserve-formula' });
  text.insert(text.length, '后');
  text.insertEmbed(text.length, { latex: 'x^2' });
  text.insertEmbed(text.length, { latex: 'x^2' });
  text.insert(text.length, '\ufffc');
  const title = m.get('p2').get('children');
  title.insertEmbed(title.length, { latex: String.raw`\sqrt{x}` });
  m.get('todo').get('children').insertEmbed(0, { latex: '' });
  m.get('fixture-doc').get('children').push(['inline-callout']);
  m.set('inline-callout', block('inline-callout', 'callout', 'block', ['inline-child'], { prefix: '💡' }));
  m.set('inline-child', block('inline-child', 'paragraph', 'editable', [
    { insert: '嵌套' }, { insert: { latex: 'E=mc^2' } }, { insert: '文字' },
  ]));
});

// 桌面用户mention: 单键对象 + 无前缀或历史d:属性；姓名可重名，ID始终独立。
fixture('blockcraft-user-mention', (_, m) => {
  const text = m.get('p1').get('children');
  text.delete(0, text.length);
  text.insert(0, '前😀', { 'a:link': 'https://example.test', customInline: 'text' });
  text.insertEmbed(text.length, { mention: '张三' }, { mentionId: 'u1', mentionType: 'user', 'a:bold': true, customInline: 'user' });
  text.insertEmbed(text.length, { mention: '张三' }, { 'd:mentionId': 'u2', 'd:mentionType': 'user', customInline: 'legacy' });
  text.insertEmbed(text.length, { latex: 'x^2' });
  text.insert(text.length, '\ufffc后');
  m.get('p2').get('children').insertEmbed(0, { mention: '标题用户' }, { mentionId: 'u1', mentionType: 'user' });
  m.get('todo').get('children').insertEmbed(0, { mention: '待办用户' }, { mentionId: 'u2', mentionType: 'user' });
  m.get('fixture-doc').get('children').push(['mention-callout']);
  m.set('mention-callout', block('mention-callout', 'callout', 'block', ['mention-child']));
  m.set('mention-child', block('mention-child', 'paragraph', 'editable', [
    { insert: { mention: '嵌套用户' }, attributes: { mentionId: 'u3', mentionType: 'user' } }
  ]));
});

// 四类提及可混排，业务元数据用于原子删除/历史恢复；不含线上内容或身份。
fixture('blockcraft-entity-mention', (_, m) => {
  const text = m.get('p1').get('children');
  text.delete(0, text.length);
  text.insert(0, '前😀');
  for (const kind of ['meeting', 'task', 'doc']) {
    text.insertEmbed(text.length, { mention: `${kind}名称` }, {
      mentionType: kind, mentionId: `${kind}-fixture`,
      [`${kind}Id`]: `${kind}-fixture`, number: '123456',
      status: { name: '未开始', fontColor: '#8c8c8c' },
      ...(kind === 'doc' ? { dc_t: 'sheets', ac_t: 'pdf' } : {}),
      customInline: { keep: true },
    });
  }
  text.insertEmbed(text.length, { mention: '同ID用户' }, { mentionId: 'meeting-fixture', mentionType: 'user' });
  text.insertEmbed(text.length, { latex: 'x^2' });
  text.insert(text.length, '\ufffc后');
  m.get('p2').get('children').insertEmbed(0, { mention: '历史会议' }, { 'd:mentionId': 'legacy-meeting', 'd:mentionType': 'meeting', customInline: true });
  m.get('fixture-doc').get('children').push(['entity-callout']);
  m.set('entity-callout', block('entity-callout', 'callout', 'block', ['entity-child']));
  m.set('entity-child', block('entity-child', 'paragraph', 'editable', [
    { insert: { mention: '嵌套任务' }, attributes: { mentionType: 'task', mentionId: 'task-child', taskId: 'task-child' } },
    { insert: '周围正文' },
  ]));
});

// MeetingCardBlockSchema: void引用，业务详情留在宿主，未知属性/损坏结构继续保留。
fixture('blockcraft-meeting', (_, m) => {
  m.get('fixture-doc').get('children').push(['meeting-1', 'meeting-empty', 'meeting-bad', 'meeting-callout']);
  m.set('meeting-1', block('meeting-1', 'meeting', 'void', [], { meetingId: 'm1', title: '项目周会😀', number: '123456', customMeeting: { keep: true } }));
  m.set('meeting-empty', block('meeting-empty', 'meeting', 'void', [], {}));
  m.set('meeting-bad', block('meeting-bad', 'meeting', 'block', ['meeting-child'], {meetingId: 'bad'}));
  m.set('meeting-child', block('meeting-child', 'paragraph', 'editable', [{insert: '保留子树'}]));
  m.set('meeting-callout', block('meeting-callout', 'callout', 'block', ['nested-meeting']));
  m.set('nested-meeting', block('nested-meeting', 'meeting', 'void', [], { meetingId: 'nested', title: null, number: null }));
});

// 正式TaskCardBlockSchema：合法引用、未知扩展及损坏身份/结构。
fixture('blockcraft-task-card', (_, m) => {
  m.get('fixture-doc').get('children').push(['task-card', 'task-invalid', 'task-bad-children']);
  m.set('task-card', block('task-card', 'task', 'void', [], {
    taskId: 'task-fixture', title: '任务卡片😀', priority: { name: '高' }, customTask: { keep: true },
  }));
  m.set('task-invalid', block('task-invalid', 'task', 'void', [], {}));
  m.set('task-bad-children', block('task-bad-children', 'task', 'block', ['task-child'], {taskId: 'bad'}));
  m.set('task-child', block('task-child', 'paragraph', 'editable', [{insert: '保留'}]));
});
