// Run the published Weather Schema and layout declarations, then encode a desktop Yjs tree.
// Usage: node tool/generate_weather_fixture.mjs <published-package> <desktop-root>
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const [packageRoot, desktopRoot] = process.argv.slice(2);
if (!packageRoot || !desktopRoot) throw Error('Published package and desktop root are required');
const version = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'))).version;
if (version !== '0.11.30') throw Error('Review weather Schema before changing the fixture version');
const source = fs.readFileSync(path.join(packageRoot, 'fesm2022/ccc-blockcraft.mjs'), 'utf8');
let nextId = 0;
const context = vm.createContext({
  WeatherBlockComponent: {}, BlockNodeType$1: {void: 'void'}, metadata: () => ({}),
  snapshot: (flavour, props) => ({id: `weather-${nextId++}`, flavour, nodeType: 'void', props, meta: {}, children: []}),
});
const layoutsStart = source.indexOf('const WEATHER_LAYOUTS =');
const layouts = source.slice(layoutsStart, source.indexOf('const resolveWeatherLayout', layoutsStart));
const schemaStart = source.indexOf('const WeatherBlockSchema =');
const schema = source.slice(schemaStart, source.indexOf('const DateCardBlockSchema =', schemaStart));
vm.runInContext(layouts + schema + '\nglobalThis.api = {schema: WeatherBlockSchema, layouts: WEATHER_LAYOUTS};', context);
const cards = context.api.layouts.map((layout, i) => {
  const card = context.api.schema.createSnapshot();
  Object.assign(card.props, {width: layout.width + 8, height: layout.height + 8, style: layout.id,
    date: '2026-10-25', frozen: {temp: 20 + i, condition: '晴', location: '北京', high: 25, low: 15, tone: 'sunny'}});
  return card;
});
cards[0].props.futureProp = {preserve: true}; cards[0].meta.audit = 'desktop';
const nested = context.api.schema.createSnapshot(); nested.id = 'nested-weather'; nested.props.date = 'live';
const malformed = context.api.schema.createSnapshot(); malformed.id = 'malformed-weather'; malformed.children = [{id: 'hidden-weather', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '保留非法子块'}]}];
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
const output = fileURLToPath(new URL('../rust/tests/fixtures/blockcraft-weather.update', import.meta.url));
fs.writeFileSync(output, Y.encodeStateAsUpdate(doc));
fs.writeFileSync(output.replace('.update', '.json'), JSON.stringify(root, null, 2) + '\n');
console.log(JSON.stringify({version, bytes: fs.statSync(output).size, styles: cards.map(c => c.props.style)}));
