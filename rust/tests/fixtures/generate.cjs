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
