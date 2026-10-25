// Generate local compatibility samples with the desktop's installed Yjs.
// No server, desktop document or dependency is modified.
import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';

const desktopRoot = process.argv[2];
if (!desktopRoot) throw Error('Usage: node tool/generate_legacy_heading_fixtures.mjs /path/to/cses-client');
const require = createRequire(path.resolve(desktopRoot, 'package.json'));
const Y = require('yjs');
const output = fileURLToPath(new URL('../rust/tests/fixtures/', import.meta.url));
const baseline = fs.readFileSync(path.join(output, 'blockcraft-basic.update'));
const fixtures = {};

/** Save an owned fixture document and its exact server state vector. */
function save(name, doc) {
  const update = Y.encodeStateAsUpdate(doc);
  const file = `blockcraft-legacy-${name}.update`;
  fs.writeFileSync(path.join(output, file), update);
  fixtures[name] = {
    file,
    stateVector: Buffer.from(Y.encodeStateVector(doc)).toString('base64'),
    sha256: createHash('sha256').update(update).digest('hex'),
  };
}

const heading = new Y.Doc();
Y.applyUpdate(heading, baseline);
heading.clientID = 783331;
heading.transact(() => {
  const props = heading.getMap('blocks').get('p1').get('props');
  props.set('heading', 9);
  props.set('nextParagraphStyle', 'same');
});
save('heading', heading);
heading.destroy();

const ordered = new Y.Doc();
Y.applyUpdate(ordered, baseline);
ordered.clientID = 783332;
ordered.transact(() => {
  const blocks = ordered.getMap('blocks');
  const root = blocks.get('fixture-doc');
  for (const id of [...blocks.keys()]) if (id !== 'fixture-doc') blocks.delete(id);
  const children = root.get('children');
  children.delete(0, children.length);
  for (const [index, level] of [7, 8, 7].entries()) {
    const id = `ordered-${index}`;
    const block = new Y.Map();
    block.set('id', id);
    block.set('flavour', 'ordered');
    block.set('nodeType', 'editable');
    block.set('props', new Y.Map([
      ['heading', level], ['depth', 0], ['order', index === 2 ? 1 : 0], ['custom', id],
    ]));
    block.set('meta', new Y.Map([['author', 'fixture-user']]));
    block.set('children', new Y.Text(`Item ${index}`));
    blocks.set(id, block);
    children.push([id]);
  }
});
save('ordered-headings', ordered);
ordered.transact(() => {
  for (const id of ['ordered-0', 'ordered-1', 'ordered-2']) {
    ordered.getMap('blocks').get(id).get('props').delete('order');
  }
});
save('ordered-missing-orders', ordered);
ordered.destroy();

fs.writeFileSync(path.join(output, 'legacy-heading-fixtures.json'), JSON.stringify({
  generatedBy: 'tool/generate_legacy_heading_fixtures.mjs',
  yjsVersion: require('yjs/package.json').version,
  fixtures,
}, null, 2) + '\n');
