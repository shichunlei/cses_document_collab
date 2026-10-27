// Run the published DateCard Schema and style declarations, then encode a desktop Yjs tree.
// Usage: node tool/generate_date_card_fixture.mjs <published-package> <desktop-root>
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const [packageRoot, desktopRoot] = process.argv.slice(2);
if (!packageRoot || !desktopRoot) throw Error('Published package and desktop root are required');
const version = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'))).version;
if (version !== '0.11.30') throw Error('Review date-card Schema before changing the fixture version');
const source = fs.readFileSync(path.join(packageRoot, 'fesm2022/ccc-blockcraft.mjs'), 'utf8');
const names = ['Calendar', 'Square', 'Banner', 'Minibar', 'Ticket', 'Stamp', 'Flip', 'Masthead', 'Bookmark', 'Split', 'Pill', 'Rail'];
let nextId = 0;
const context = vm.createContext({
  ...Object.fromEntries(names.map(name => [name + 'CardComponent', {}])),
  DateCardRenderComponent: {}, BlockNodeType$1: {void: 'void'},
  DATE_FORMATS: {Full: 'full', NoWeek: 'noWeek', Min: 'min'},
  metadata: () => ({}),
  snapshot: (flavour, props) => ({id: `date-${nextId++}`, flavour, nodeType: 'void', props, meta: {}, children: []}),
});
const helpers = source.slice(source.indexOf('const MATERIAL_FRAME_PADDING_PX ='), source.indexOf('/**\n * 「一个物料，N 种长相」'));
const styles = source.slice(source.indexOf('const DATE_CARD_STYLES ='), source.indexOf('\n/**', source.indexOf('const DATE_CARD_STYLES =')));
const schema = source.slice(source.indexOf('const DateCardBlockSchema ='), source.indexOf('const PersonCardBlockSchema ='));
vm.runInContext(helpers + `\nfunction defineMaterialStyles(key,label,all) { return {all, defaultSize: materialStyleFixedSize(all[0])}; }\n` + styles + '\n' + schema + '\nglobalThis.api = {schema: DateCardBlockSchema, styles: DATE_CARD_STYLES, size: materialStyleFixedSize};', context);
const cards = context.api.styles.all.map((style, i) => {
  const card = context.api.schema.createSnapshot();
  Object.assign(card.props, context.api.size(style), {
    date: '2026-10-25T09:30', style: style.id, format: ['full', 'noWeek', 'min'][i % 3],
    fg: i % 2 ? '#24324b' : '', bg: i % 2 ? '#e6edf8' : '',
  });
  return card;
});
cards[0].props.futureProp = {preserve: true}; cards[0].meta.audit = 'desktop';
const nested = context.api.schema.createSnapshot(); nested.id = 'nested-date'; nested.props.date = '2024-02-29T23:59';
const malformed = context.api.schema.createSnapshot(); malformed.id = 'malformed-date'; malformed.children = [{id: 'hidden-date', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '保留非法子块'}]}];
const root = {id: 'fixture-doc', flavour: 'root', nodeType: 'root', props: {}, meta: {}, children: [
  ...cards, {id: 'tail', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '保留正文'}]},
  {id: 'box', flavour: 'callout', nodeType: 'block', props: {}, meta: {}, children: [nested]}, malformed,
]};
const require = createRequire(path.resolve(desktopRoot, 'package.json'));
const Y = require('yjs');
const doc = new Y.Doc(); doc.clientID = 83025;
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
doc.transact(() => insert(root));
const output = fileURLToPath(new URL('../rust/tests/fixtures/blockcraft-date-card.update', import.meta.url));
fs.writeFileSync(output, Y.encodeStateAsUpdate(doc));
fs.writeFileSync(output.replace('.update', '.json'), JSON.stringify(root, null, 2) + '\n');
console.log(JSON.stringify({version, bytes: fs.statSync(output).size, styles: cards.map(c => c.props.style)}));
