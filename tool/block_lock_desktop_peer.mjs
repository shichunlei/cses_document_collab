// Exercise the published desktop BlockReadonlyManager with its real Yjs/RxJS
// dependencies. Only the mounted-view/model-query host is supplied by this tool.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';

const [desktopRoot, packageRoot, directory, phase = 'prepare'] = process.argv.slice(2);
if (!directory) throw Error('Usage: node tool/block_lock_desktop_peer.mjs <desktop-root> <package-root> <output-dir> [prepare|receive|final]');
const require = createRequire(path.resolve(desktopRoot, 'package.json'));
const Y = require('yjs');
const rx = require('rxjs');
const source = fs.readFileSync(path.join(packageRoot, 'fesm2022/ccc-blockcraft.mjs'), 'utf8');
const start = source.indexOf('function normalizeUserId(value)');
const end = source.indexOf('/** @internal Document-owned coordinator', start);
if (start < 0 || end < 0) throw Error('Desktop lock implementation changed; review extraction boundary');
class FrameworkError extends Error { constructor(options, text) { super(text ?? options?.reason ?? String(options)); Object.assign(this, options); } }
const context = vm.createContext({Y, ...rx, BlockCraftError: FrameworkError, BlockLockError: FrameworkError,
  BlockReadonlyError: FrameworkError, ErrorCode: {ModelCRUDError: 'model'},
  BlockReadonlyOperation: {Lock: 'lock', Unlock: 'unlock'}, ORIGIN_BLOCK_READONLY_CONTROL: Symbol('lock')});
vm.runInContext(source.slice(start, end) + ';globalThis.Manager = BlockReadonlyManager;', context);
const rootId = 'fixture-doc';
const doc = new Y.Doc();
const blocks = doc.getMap('blocks');
const metadata$ = new rx.Subject();
let extraGrant = false;
const host = {
  rootId, isReadonly: false, config: {currentUserId: 'desktop-user', canUnlockBlock: () => extraGrant}, vm: {},
  logger: {warn: (...args) => { throw Error(args.join(' ')); }},
  afterInit: callback => callback(), onDestroy: () => {}, onMetaUpdate$: metadata$,
  readonlySwitch$: new rx.BehaviorSubject(false),
  model: {
    structureRevision: 0, structureChange$: new rx.Subject(), exists: id => blocks.has(id),
    getYBlock: id => blocks.get(id),
    getChildrenIds: id => { const children = blocks.get(id)?.get('children'); return children instanceof Y.Array ? children.toArray() : []; },
    getPath: id => {
      const queue = [[rootId]];
      while (queue.length) { const chain = queue.shift(); if (chain.at(-1) === id) return chain;
        for (const child of host.model.getChildrenIds(chain.at(-1))) queue.push([...chain, child]); }
      return null;
    },
  },
  crud: {transact: (callback, origin) => doc.transact(callback, origin)},
};
function insert(id, flavour, children, props = {}) {
  const block = new Y.Map(); blocks.set(id, block);
  block.set('id', id); block.set('flavour', flavour);
  block.set('nodeType', flavour === 'root' ? 'root' : flavour === 'callout' ? 'block' : 'editable');
  const meta = new Y.Map(); block.set('meta', meta); meta.set('audit', 'keep-desktop');
  const values = new Y.Map(); block.set('props', values);
  for (const [key, value] of Object.entries(props)) values.set(key, value);
  if (typeof children === 'string') { const text = new Y.Text(); block.set('children', text); text.insert(0, children); }
  else { const array = new Y.Array(); block.set('children', array); array.push(children); }
}
fs.mkdirSync(directory, {recursive: true});
const file = name => path.join(directory, name);
if (phase === 'prepare') {
  doc.clientID = 101922;
  doc.transact(() => {
    insert(rootId, 'root', ['p1', 'p2', 'callout']);
    insert('p1', 'paragraph', '桌面定稿'); insert('p2', 'paragraph', '开放正文');
    insert('callout', 'callout', ['child'], {prefix: '💡'}); insert('child', 'paragraph', '容器正文');
  });
  fs.writeFileSync(file('baseline.update'), Y.encodeStateAsUpdate(doc));
} else {
  Y.applyUpdate(doc, fs.readFileSync(file('desktop-state.update')));
  Y.applyUpdate(doc, fs.readFileSync(file(phase === 'receive' ? 'phone.update' : 'phone-final.update')));
}
const manager = new context.Manager(host);
doc.on('afterTransaction', () => {
  metadata$.next({transactions: [...blocks.keys()].map(blockId => ({blockId, changes: new Set(['lock', 'lockKind'])}))});
});
if (phase === 'prepare') {
  manager.set('p1', true); manager.set('callout', true);
  assert.equal(manager.isReadonly('child'), true);
  assert.equal(manager.canUnlock('child'), false);
  assert.throws(() => manager.set('child', false));
  assert.throws(() => manager.set(rootId, true));
  fs.writeFileSync(file('desktop-lock.update'), Y.encodeStateAsUpdate(doc));
} else if (phase === 'receive') {
  assert.equal(manager.isReadonly('p1'), false, 'mobile owner/admin unlock must reach desktop');
  assert.equal(manager.isReadonly('p2'), true, 'mobile lock must reach desktop');
  assert.equal(manager.getExplicitLockUserId('p2'), 'phone-user');
  assert.equal(manager.canUnlock('p2'), false);
  assert.throws(() => manager.set('p2', false));
  extraGrant = true; manager.set('p2', false); manager.set('callout', false);
  manager.set('p1', true, {kind: 'template'});
  extraGrant = false;
  assert.equal(manager.canUnlock('p1'), false, 'template author needs an explicit grant');
  fs.writeFileSync(file('desktop-return.update'), Y.encodeStateAsUpdate(doc));
} else if (phase === 'final') {
  for (const id of ['p1', 'p2', 'callout', 'child']) assert.equal(manager.isReadonly(id), false);
  assert.match(blocks.get('p2').get('children').toString(), /手机可编辑/);
  assert.equal(blocks.get('p1').get('meta').get('audit'), 'keep-desktop');
}
fs.writeFileSync(file('desktop-state.update'), Y.encodeStateAsUpdate(doc));
manager.destroy(); doc.destroy();
console.log(JSON.stringify({phase, packageVersion: JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'))).version,
  lockImplementationSha256: createHash('sha256').update(source.slice(start, end)).digest('hex'), passed: true}));
