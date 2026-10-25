// Run the published PersonCard Schema and layout declarations, then encode a desktop Yjs tree.
// Usage: node tool/generate_person_card_fixture.mjs <published-package> <desktop-root>
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const [packageRoot, desktopRoot] = process.argv.slice(2);
if (!packageRoot || !desktopRoot) throw Error('Published package and desktop root are required');
const version = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'))).version;
if (version !== '0.11.30') throw Error('Review person-card Schema before changing the fixture version');
const source = fs.readFileSync(path.join(packageRoot, 'fesm2022/ccc-blockcraft.mjs'), 'utf8');
let nextId = 0;
const context = vm.createContext({
  PersonCardRenderComponent: {}, RowCardComponent: {}, RowPinyinCardComponent: {}, ColumnCardComponent: {},
  BlockNodeType$1: {void: 'void'}, metadata: () => ({}), MATERIAL_FRAME_PADDING_PX: 4,
  previewUnitOf: () => 1, personCardContentScale: props => props.sc ?? 1,
  snapshot: (flavour, props) => ({id: `person-${nextId++}`, flavour, nodeType: 'void', props, meta: {}, children: []}),
});
const sizeStart = source.indexOf('const arOf =');
const sizeEnd = source.indexOf('/**', source.indexOf('function materialStyleFixedSize', sizeStart));
const helperStart = source.indexOf('function defineMaterialStyles(');
const helperEnd = source.indexOf('\n}', helperStart) + 2;
const styleStart = source.lastIndexOf('const styles = defineMaterialStyles', source.indexOf('const PERSON_CARD_STYLES'));
const styleEnd = source.indexOf('const PERSON_CARD_WATCHED_PROPS', styleStart);
const schemaStart = source.indexOf('const PersonCardBlockSchema =');
const schemaEnd = source.indexOf('\n};', schemaStart) + 3;
vm.runInContext(source.slice(sizeStart, sizeEnd) + source.slice(helperStart, helperEnd) + source.slice(styleStart, styleEnd)
  + source.slice(schemaStart, schemaEnd) + '\nglobalThis.api = {schema: PersonCardBlockSchema, styles: PERSON_CARD_STYLES};', context);
const cards = context.api.styles.all.map(style => {
  const card = context.api.schema.createSnapshot();
  Object.assign(card.props, context.materialStyleFixedSize(style), {style: style.id,
    person: JSON.stringify({name: '张三', pinyin: 'ZHANG SAN', description: '研发部 / 工程师'}), dept: 'on'});
  card.props.width = Math.round(card.props.width); card.props.height = Math.round(card.props.height);
  return card;
});
cards[0].props.futureProp = {preserve: true}; cards[0].meta.audit = 'desktop';
const nested = context.api.schema.createSnapshot(); nested.id = 'nested-person-card'; delete nested.props.sc;
const malformed = context.api.schema.createSnapshot(); malformed.id = 'malformed-person-card'; malformed.children = [{id: 'hidden-person-card', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '保留非法子块'}]}];
const root = {id: 'fixture-doc', flavour: 'root', nodeType: 'root', props: {}, meta: {}, children: [
  ...cards, {id: 'tail', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '保留正文'}]},
  {id: 'box', flavour: 'callout', nodeType: 'block', props: {}, meta: {}, children: [nested]}, malformed,
]};
const require = createRequire(path.resolve(desktopRoot, 'package.json'));
const Y = require('yjs');
const doc = new Y.Doc(); doc.clientID = 84025;
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
const output = fileURLToPath(new URL('../rust/tests/fixtures/blockcraft-person-card.update', import.meta.url));
fs.writeFileSync(output, Y.encodeStateAsUpdate(doc));
fs.writeFileSync(output.replace('.update', '.json'), JSON.stringify(root, null, 2) + '\n');
console.log(JSON.stringify({version, bytes: fs.statSync(output).size, styles: cards.map(c => c.props.style)}));
