// Execute the installed desktop Schema; compare its text-box contract to the reviewed latest artifact.
// Usage: node tool/generate_text_box_fixture.mjs <desktop-root> <latest-package>
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL, fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
const [desktop, latest] = process.argv.slice(2);
const installed = path.join(desktop, 'node_modules/@ccc/blockcraft');
const read = root => fs.readFileSync(path.join(root, 'fesm2022/ccc-blockcraft.mjs'), 'utf8');
const slice = source => source.slice(source.indexOf('const TextBoxBlockSchema ='), source.indexOf('/**', source.indexOf('const TextBoxBlockSchema =')));
if (slice(read(installed)) !== slice(read(latest))) throw Error('TextBox Schema changed: review before generating');
await import(pathToFileURL(path.join(desktop, 'node_modules/@angular/compiler/fesm2022/compiler.mjs')));
const bc = await import(pathToFileURL(path.join(installed, 'fesm2022/ccc-blockcraft.mjs')));
const box = bc.TextBoxBlockSchema.createSnapshot('文本框正文', {width: 300, height: 160, fill: '#FFF3C4', outline: '2px solid #334455', textPadding: '8 12'});
box.id = 'text-box'; box.children[0].id = 'box-body'; box.children[0].children[0].attributes = {'a:bold': true};
box.props.futureProp = {preserve: true}; box.meta.audit = 'desktop';
const malformed = bc.TextBoxBlockSchema.createSnapshot(''); malformed.id = 'malformed-box'; malformed.children = [bc.TextBoxBlockSchema.createSnapshot('不能丢弃')];
malformed.children[0].id = 'nested-box'; malformed.children[0].children[0].id = 'hidden-body';
const tail = bc.ParagraphBlockSchema.createSnapshot('后续正文'); tail.id = 'tail';
const root = {id: 'fixture-doc', flavour: 'root', nodeType: 'root', props: {}, meta: {}, children: [box, tail, malformed]};
const require = createRequire(path.join(desktop, 'package.json'));
const Y = require('yjs'); const doc = new Y.Doc(); doc.clientID = 841026;
const blocks = doc.getMap('blocks');
function insert(value) {
  const block = new Y.Map(); blocks.set(value.id, block);
  for (const key of ['id', 'flavour', 'nodeType']) block.set(key, value[key]);
  for (const key of ['props', 'meta']) { const map = new Y.Map(); block.set(key, map); for (const [k,v] of Object.entries(value[key])) map.set(k,v); }
  if (value.nodeType === 'editable') { const text = new Y.Text(); block.set('children',text); text.applyDelta(value.children); }
  else { const children = new Y.Array(); block.set('children', children); children.push(value.children.map(c=>c.id)); value.children.forEach(insert); }
}
doc.transact(()=>insert(JSON.parse(JSON.stringify(root))));
const output = fileURLToPath(new URL('../rust/tests/fixtures/blockcraft-text-box.update', import.meta.url));
fs.writeFileSync(output,Y.encodeStateAsUpdate(doc)); fs.writeFileSync(output.replace('.update','.json'),JSON.stringify(root,null,2)+'\n');
console.log(JSON.stringify({factoryVersion:JSON.parse(fs.readFileSync(path.join(installed,'package.json'))).version, reviewedVersion:JSON.parse(fs.readFileSync(path.join(latest,'package.json'))).version,schemaSHA256:createHash('sha256').update(slice(read(installed))).digest('hex'),bytes:fs.statSync(output).size}));
