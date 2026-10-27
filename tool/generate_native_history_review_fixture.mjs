// Generate a deterministic independent Yjs snapshot for native-history review tests.
// Usage: node tool/generate_native_history_review_fixture.mjs /path/to/cses-client
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const directory = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(resolve(process.argv[2], 'package.json'));
const Y = require('yjs');
const basePath = 'rust/tests/fixtures/blockcraft-ordered.update';
const base = readFileSync(resolve(directory, basePath));
const doc = new Y.Doc();
Y.applyUpdate(doc, base);
const clientId = 420100;
doc.clientID = clientId;
const missingOrderIds = ['a', 'b', 'c'];
const blocks = doc.getMap('blocks');
doc.transact(() => {
  for (const id of missingOrderIds) blocks.get(id).get('props').delete('order');
});
const output = {
  generator: 'tool/generate_native_history_review_fixture.mjs',
  yjsVersion: require('yjs/package.json').version,
  clientId,
  basePath,
  baseSha256: createHash('sha256').update(base).digest('hex'),
  rootId: 'fixture-doc',
  missingOrderIds,
  update: [...Y.encodeStateAsUpdate(doc)],
  stateVector: [...Y.encodeStateVector(doc)],
};
writeFileSync(resolve(directory, 'rust/tests/fixtures/native-history-review.json'), JSON.stringify(output, null, 2) + '\n');
doc.destroy();
