import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';

// Reuse the existing desktop Schema fixture; this generator only changes its root subset.
const directory = path.dirname(fileURLToPath(import.meta.url));
const desktop = process.argv[2];
const Y = createRequire(path.join(desktop, 'package.json'))('yjs');
const source = JSON.parse(fs.readFileSync(path.join(directory, '../../../test/fixtures/desktop-json-blocks.json')));
const kinds = new Set(['paragraph', 'shape', 'word-art', 'object-group', 'placement-layout', 'render-unit', 'task-list', 'mind-map']);
source.children = source.children.filter(block => kinds.has(block.flavour));
const doc = new Y.Doc();
doc.clientID = 841027;
const blocks = doc.getMap('blocks');

/** Insert an existing snapshot without changing its props, meta or descendants. */
function insert(snapshot) {
  const block = new Y.Map();
  blocks.set(snapshot.id, block);
  for (const key of ['id', 'flavour', 'nodeType']) block.set(key, snapshot[key]);
  for (const key of ['props', 'meta']) {
    const map = new Y.Map();
    block.set(key, map);
    for (const [name, value] of Object.entries(snapshot[key])) map.set(name, value);
  }
  if (snapshot.nodeType === 'editable') {
    const text = new Y.Text();
    block.set('children', text);
    text.applyDelta(snapshot.children);
  } else {
    const children = new Y.Array();
    block.set('children', children);
    children.push(snapshot.children.map(child => child.id));
    snapshot.children.forEach(insert);
  }
}
doc.transact(() => insert(source));
fs.writeFileSync(path.join(directory, 'json-only.update'), Y.encodeStateAsUpdate(doc));
doc.destroy();
