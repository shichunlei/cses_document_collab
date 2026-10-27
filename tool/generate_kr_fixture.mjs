// Use the desktop KR Schema factory and desktop Yjs encoder, without starting Angular.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const [desktopRoot] = process.argv.slice(2);
if (!desktopRoot) throw Error('Usage: node tool/generate_kr_fixture.mjs <desktop-root>');
const schema = fs.readFileSync(path.join(desktopRoot, 'packages/docs/src/editor/embedded-references/kr-list/index.ts'), 'utf8');
const factory = schema.match(/createSnapshot: (\(input: \{ meetingId: string \}\) => \(\{[\s\S]*?\}\)),/);
if (!factory) throw Error('KR Schema changed: review factory and fixture generator');
const context = vm.createContext({generateId: () => 'kr-list-1', BlockNodeType: {void: 'void'}});
vm.runInContext('globalThis.create = ' + factory[1].replace('(input: { meetingId: string })', '(input)'), context);
const kr = context.create({meetingId: 'm1'});
kr.props.estimatedHeight = 200; kr.props.future = 'keep'; kr.meta.audit = 'desktop';
const invalid = {...context.create({meetingId: ''}), id: 'kr-invalid'};
const malformed = {...context.create({meetingId: 'm1'}), id: 'kr-malformed', children: [
  {id: 'hidden', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '保留'}]},
]};
const root = {id: 'fixture-doc', flavour: 'root', nodeType: 'root', props: {}, meta: {}, children: [kr,
  {id: 'tail', flavour: 'paragraph', nodeType: 'editable', props: {}, meta: {}, children: [{insert: '正文'}]}, invalid, malformed]};
const require = createRequire(path.resolve(desktopRoot, 'package.json'));
const Y = require('yjs');
const doc = new Y.Doc(); doc.clientID = 81919;
const blocks = doc.getMap('blocks');
function insert(snapshot) {
  const model = new Y.Map(); blocks.set(snapshot.id, model);
  for (const key of ['id', 'flavour', 'nodeType']) model.set(key, snapshot[key]);
  for (const key of ['props', 'meta']) {
    const map = new Y.Map(); model.set(key, map);
    for (const [k,v] of Object.entries(snapshot[key])) map.set(k,v);
  }
  if (snapshot.nodeType === 'editable') {
    const text = new Y.Text(); model.set('children', text); text.applyDelta(snapshot.children);
  } else {
    const children = new Y.Array(); model.set('children', children);
    children.push(snapshot.children.map(child => child.id)); snapshot.children.forEach(insert);
  }
}
doc.transact(() => insert(root));
const output = fileURLToPath(new URL('../rust/tests/fixtures/blockcraft-kr.update', import.meta.url));
fs.writeFileSync(output, Y.encodeStateAsUpdate(doc));
console.log(JSON.stringify({output, bytes: fs.statSync(output).size, source: 'desktop KrListBlockSchema'}));
