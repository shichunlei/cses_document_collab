// Generate a formal Yjs fixture from the published page-divider Schema factory.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const [packageRoot, desktopRoot] = process.argv.slice(2);
if (!packageRoot || !desktopRoot) throw Error('Usage: node tool/generate_page_divider_fixture.mjs <published-package> <desktop-root>');
const version = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'))).version;
if (version !== '0.11.21') throw Error('Review Schema and migration changes before changing the fixture version');
const source = fs.readFileSync(path.join(packageRoot, 'fesm2022/ccc-blockcraft.mjs'), 'utf8');
const start = source.indexOf('const PageDividerBlockSchema =');
const end = source.indexOf('\nclass ', start);
if (start < 0 || end < 0) throw Error('Published page-divider Schema not found');
let nextId = 0;
const context = vm.createContext({generateId: () => `break-${++nextId}`, BlockNodeType$1: {void: 'void'}, PageDividerBlockComponent: {}});
vm.runInContext(source.slice(start, end) + '\nglobalThis.schema = PageDividerBlockSchema;', context);
if (context.schema.metadata.rootOnly !== true) throw Error('Expected rootOnly Schema');
const first = context.schema.createSnapshot();
first.props.futureProp = {preserve: true}; first.meta.audit = 'desktop';
const second = context.schema.createSnapshot();
const nested = context.schema.createSnapshot(); nested.id = 'nested-break';
const malformed = context.schema.createSnapshot(); malformed.id = 'malformed-break';
malformed.children = [{id: 'hidden', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '保留非法子块'}]}];
const root = {id: 'fixture-doc', flavour: 'root', nodeType: 'root', props: {}, meta: {}, children: [
  first, second,
  {id: 'tail', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '保留正文'}]},
  {id: 'box', flavour: 'callout', nodeType: 'block', props: {prefix: '💡'}, meta: {}, children: [nested]},
  malformed,
]};
const require = createRequire(path.resolve(desktopRoot, 'package.json'));
const Y = require('yjs');
const doc = new Y.Doc(); doc.clientID = 81821;
const blocks = doc.getMap('blocks');
function insert(snapshot) {
  const model = new Y.Map(); blocks.set(snapshot.id, model);
  for (const key of ['id', 'flavour', 'nodeType']) model.set(key, snapshot[key]);
  for (const key of ['props', 'meta']) {
    const map = new Y.Map(); model.set(key, map);
    for (const [k, v] of Object.entries(snapshot[key])) map.set(k, v);
  }
  if (snapshot.nodeType === 'editable') {
    const text = new Y.Text(); model.set('children', text); text.applyDelta(snapshot.children);
  } else {
    const children = new Y.Array(); model.set('children', children);
    children.push(snapshot.children.map(c => c.id)); snapshot.children.forEach(insert);
  }
}
doc.transact(() => insert(root));
const output = fileURLToPath(new URL('../rust/tests/fixtures/blockcraft-page-divider.update', import.meta.url));
fs.writeFileSync(output, Y.encodeStateAsUpdate(doc));
console.log(JSON.stringify({version, output, bytes: fs.statSync(output).size, rootOnly: context.schema.metadata.rootOnly}));
