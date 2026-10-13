// 脱敏 FRB 输出用实际已安装桌面包的计数/格式化实现回读，避免两份移植代码自证正确。
// node verify-ordered.cjs <yjs路径> <ccc-blockcraft.mjs路径> <FRB输出update路径> [编号命令输出路径]
const fs = require('fs');
const vm = require('vm');
const assert = require('node:assert/strict');
const Y = require(process.argv[2] || 'yjs');
const source = fs.readFileSync(process.argv[3], 'utf8');
function section(from, to) {
  const start = source.indexOf(from);
  const end = source.indexOf(to, start);
  assert(start >= 0 && end > start, `桌面实现边界变更：${from}`);
  return source.slice(start, end);
}
const context = vm.createContext({});
vm.runInContext([
  section('function number2letter(n)', 'const normalizeOrderedCounterInteger'),
  section('const normalizeOrderedCounterInteger', 'const readBlock ='),
  section('const getOrderableBlock =', "const MATCH_COLOR ="),
  'globalThis.verify = { updateOrdersInParent, resolveOrderedMarker };',
].join('\n'), context);

function verify(path, expected) {
  const doc = new Y.Doc({ gc: false });
  Y.applyUpdate(doc, fs.readFileSync(`${__dirname}/blockcraft-basic.update`));
  const blocks = doc.getMap('blocks');
  const events = [];
  blocks.observeDeep(batch => events.push(...batch.map(event => ({ path: [...event.path], keys: new Set(event.changes.keys.keys()) }))));
  Y.applyUpdate(doc, fs.readFileSync(path));
  const ids = blocks.get('fixture-doc').get('children').toArray();
  assert.equal(ids.length, expected.length);
  assert(!blocks.has('p1'), '旧段落身份必须删除，让桌面销毁段落组件');
  assert(events.some(event => event.path[0] === 'fixture-doc' && event.path[1] === 'children'), '父 children 必须产生结构事件');
  assert(events.some(event => event.path.length === 0 && event.keys.has('p1')), '旧身份必须产生 Map 删除事件');
  const patches = [];
  const desktop = {
    model: {
      getFlavour: id => blocks.get(id)?.get('flavour'),
      getProps: id => blocks.get(id)?.get('props').toJSON(),
      getChildrenIds: id => blocks.get(id).get('children').toArray(),
    },
    crud: { updateBlockProps: (id, props) => patches.push({ id, props }) },
  };
  context.verify.updateOrdersInParent(desktop, 'fixture-doc', new Set());
  assert.deepEqual(patches, [], '桌面重新扫描不得发现需要纠正的 order');
  const markers = ids.map(id => {
    const block = blocks.get(id);
    assert.equal(block.get('flavour'), 'ordered');
    const props = block.get('props');
    assert(props.has('order'));
    return context.verify.resolveOrderedMarker(props.get('order'), props.get('depth') || 0, props.get('ms')).text;
  });
  assert.deepEqual(markers, expected);
  assert.deepEqual(blocks.get(ids[0]).get('props').get('customProp'), { enabled: true });
  assert(blocks.get(ids[0]).get('meta').has('customAudit'));
  assert(blocks.get(ids[0]).get('children').toDelta().some(delta => delta.attributes?.['a:link'] === 'https://example.test'));
  doc.destroy();
  console.log(`桌面实际实现回读通过：${markers.join(' ')}`);
}
verify(process.argv[4], ['1.', '2.', '3.']);
verify(`${process.argv[4]}.deleted`, ['1.', '2.']);

// 带 start/ms/heading 的真实桌面样本在手机重排、缩进后仍无需桌面纠正，缺失 ms 的既有项不隐式继承。
const doc = new Y.Doc({ gc: false });
Y.applyUpdate(doc, fs.readFileSync(`${process.argv[4]}.boundaries`));
const blocks = doc.getMap('blocks');
const patches = [];
const desktop = {
  model: {
    getFlavour: id => blocks.get(id)?.get('flavour'),
    getProps: id => blocks.get(id)?.get('props').toJSON(),
    getChildrenIds: id => blocks.get(id).get('children').toArray(),
  },
  crud: { updateBlockProps: (id, props) => patches.push({ id, props }) },
};
context.verify.updateOrdersInParent(desktop, 'fixture-doc', new Set());
assert.deepEqual(patches, []);
const markers = desktop.model.getChildrenIds('fixture-doc').filter(id => desktop.model.getFlavour(id) === 'ordered').map(id => {
  const props = desktop.model.getProps(id);
  return context.verify.resolveOrderedMarker(props.order, props.depth, props.ms).text;
});
assert.deepEqual(markers, ['1.', 'B.', '1)', '3.', '4.', '5.', '6.', '1.', '2.', '1.']);
assert.equal(blocks.get('restart').get('props').get('start'), 5);
assert.equal(blocks.get('restart').get('props').get('ms'), null);
console.log(`桌面重排/缩进/start/ms/heading 回读通过：${markers.join(' ')}`);
doc.destroy();

// 可选的编号菜单 FRB 输出：同一批既有身份只修改编号设置与派生 order。
if (process.argv[5]) {
  const numbered = new Y.Doc({ gc: false });
  const original = new Y.Doc({ gc: false });
  Y.applyUpdate(numbered, fs.readFileSync(process.argv[5]));
  Y.applyUpdate(original, fs.readFileSync(`${__dirname}/blockcraft-ordered.update`));
  const values = numbered.getMap('blocks');
  const initial = original.getMap('blocks');
  const ids = values.get('fixture-doc').get('children').toArray();
  assert.deepEqual(ids, initial.get('fixture-doc').get('children').toArray());
  const corrections = [];
  const mobile = {
    model: {
      getFlavour: id => values.get(id)?.get('flavour'),
      getProps: id => values.get(id)?.get('props').toJSON(),
      getChildrenIds: id => values.get(id).get('children').toArray(),
    },
    crud: { updateBlockProps: (id, props) => corrections.push({ id, props }) },
  };
  context.verify.updateOrdersInParent(mobile, 'fixture-doc', new Set());
  assert.deepEqual(corrections, []);
  const outputMarkers = ids.filter(id => mobile.model.getFlavour(id) === 'ordered').map(id => {
    const props = mobile.model.getProps(id);
    return context.verify.resolveOrderedMarker(props.order, props.depth, props.ms).text;
  });
  assert.deepEqual(outputMarkers, ['A.', '2.', '1)', 'b.', '3.', '1.', '2.', '1.', '2.', '1.']);
  for (const [id, start, mode] of [['b', 0, true], ['restart', 1, false]]) {
    assert.equal(values.get(id).get('props').get('start'), start);
    assert.equal(values.get(id).get('props').get('continuePrevious'), mode);
  }
  for (const id of ids) {
    const item = values.get(id);
    const old = initial.get(id);
    assert.equal(item.get('flavour'), old.get('flavour'));
    assert.deepEqual(item.get('children').toDelta(), old.get('children').toDelta());
    assert.deepEqual(item.get('meta').toJSON(), old.get('meta').toJSON());
    const props = item.get('props').toJSON();
    const oldProps = old.get('props').toJSON();
    for (const key of ['order', 'start', 'continuePrevious']) {
      delete props[key];
      delete oldProps[key];
    }
    assert.deepEqual(props, oldProps);
  }
  numbered.destroy();
  original.destroy();
  console.log(`桌面继续/重新编号及身份/正文/扩展属性回读通过：${outputMarkers.join(' ')}`);
}
