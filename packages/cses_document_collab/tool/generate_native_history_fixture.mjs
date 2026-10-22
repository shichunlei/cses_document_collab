// Generate independent Yjs peer updates against the existing formal base fixture.
// Usage: node tool/generate_native_history_fixture.mjs /path/to/cses-client
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const directory = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(process.argv[2], 'package.json'));
const Y = require('yjs');
const base = readFileSync(resolve(directory, 'rust/tests/fixtures/blockcraft-basic.update'));
const initial = new Y.Doc();
Y.applyUpdate(initial, base);
const blocks = initial.getMap('blocks');
const root = [...blocks.values()].find(block => block.get('flavour') === 'root');
const id = root.get('children').toArray().find(id => blocks.get(id)?.get('children') instanceof Y.Text);
const order = root.get('children').toArray();
const updates = {};
for (const [index, kind] of ['prefix', 'reorder', 'lock', 'delete', 'format'].entries()) {
  const doc = new Y.Doc();
  Y.applyUpdate(doc, base);
  doc.clientID = 420000 + index;
  const vector = Y.encodeStateVector(doc);
  const map = doc.getMap('blocks');
  const parent = map.get(root.get('id'));
  const children = parent.get('children');
  doc.transact(() => {
    if (kind === 'prefix') map.get(id).get('children').insert(0, '远端-');
    if (kind === 'format') map.get(id).get('children').format(0, map.get(id).get('children').length, {'a:italic': true});
    if (kind === 'lock') map.get(id).get('meta').set('lock', 'remote-owner');
    if (kind === 'reorder') { const position = children.toArray().indexOf(id); children.delete(position, 1); children.push([id]); }
    if (kind === 'delete') { const position = children.toArray().indexOf(id); children.delete(position, 1); map.delete(id); }
  });
  updates[kind] = [...Y.encodeStateAsUpdate(doc, vector)];
  if (kind === 'lock') {
    const locked = Y.encodeStateVector(doc);
    map.get(id).get('meta').delete('lock');
    updates.unlock = [...Y.encodeStateAsUpdate(doc, locked)];
  }
  doc.destroy();
}
const output = {baseSha256: createHash('sha256').update(base).digest('hex'), paragraphId: id,
  rootId: root.get('id'), originalOrder: order, text: blocks.get(id).get('children').toString(), updates};
writeFileSync(resolve(directory, 'rust/tests/fixtures/native-history-peer.json'), JSON.stringify(output, null, 2) + '\n');
initial.destroy();
