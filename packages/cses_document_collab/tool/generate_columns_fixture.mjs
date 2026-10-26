// Execute the published column/columns Schema factories and encode a desktop Yjs fixture.
// Usage: node tool/generate_columns_fixture.mjs <published-package> <desktop-root>
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const [packageRoot, desktopRoot] = process.argv.slice(2);
if (!packageRoot || !desktopRoot) throw Error('Published package and desktop root are required');
const version = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'))).version;
if (version !== '0.11.30') throw Error('Review columns Schema before changing fixture version');
const source = fs.readFileSync(path.join(packageRoot, 'fesm2022/ccc-blockcraft.mjs'), 'utf8');
let id = 0;
const paragraph = (text = '') => ({id: `text-${id++}`, flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: text ? [{insert: text, attributes: {'a:bold': true}}] : []});
const context = vm.createContext({ColumnBlockComponent: {}, ColumnsBlockComponent: {}, BlockNodeType$1: {block: 'block'}, nanoid: () => `block-${id++}`, ParagraphBlockSchema: {createSnapshot: paragraph}});
const start = source.indexOf('const ColumnBlockSchema =');
const end = source.indexOf('class FormulaBlockComponent', start);
vm.runInContext(source.slice(start, end) + '\nglobalThis.api = {ColumnBlockSchema, ColumnsBlockSchema};', context);
const columns = context.api.ColumnsBlockSchema.createSnapshot(2);
columns.id = 'columns'; columns.props.columnWidths = [30, 70];
columns.props.futureProp = {preserve: true}; columns.meta.audit = 'desktop';
columns.children.forEach((c, i) => {c.id = `column-${i}`; c.props.columnIndex = i; c.children = [paragraph(`第${i + 1}列正文`)]; c.children[0].id = `body-${i}`;});
const nested = context.api.ColumnsBlockSchema.createSnapshot(2); nested.id = 'nested-columns';
const malformed = context.api.ColumnsBlockSchema.createSnapshot(2); malformed.id = 'malformed-columns'; malformed.children[0] = paragraph('保留不合法子块');
const root = {id: 'fixture-doc', flavour: 'root', nodeType: 'root', props: {}, meta: {}, children: [columns, paragraph('后续正文'), {id: 'box', flavour: 'callout', nodeType: 'block', props: {}, meta: {}, children: [nested]}, malformed]};
const require = createRequire(path.resolve(desktopRoot, 'package.json'));
const Y = require('yjs');
const doc = new Y.Doc(); doc.clientID = 84026;
const blocks = doc.getMap('blocks');
function insert(value) {
  const model = new Y.Map(); blocks.set(value.id, model);
  for (const key of ['id', 'flavour', 'nodeType']) model.set(key, value[key]);
  for (const key of ['props', 'meta']) {
    const map = new Y.Map(); model.set(key, map);
    for (const [k, v] of Object.entries(value[key])) map.set(k, v);
  }
  if (value.nodeType === 'editable') {
    const text = new Y.Text(); model.set('children', text); text.applyDelta(value.children);
  } else {
    const children = new Y.Array(); model.set('children', children);
    children.push(value.children.map(c => c.id)); value.children.forEach(insert);
  }
}
doc.transact(() => insert(JSON.parse(JSON.stringify(root))));
const output = fileURLToPath(new URL('../rust/tests/fixtures/blockcraft-columns.update', import.meta.url));
fs.writeFileSync(output, Y.encodeStateAsUpdate(doc));
fs.writeFileSync(output.replace('.update', '.json'), JSON.stringify(root, null, 2) + '\n');
console.log(JSON.stringify({version, bytes: fs.statSync(output).size}));
