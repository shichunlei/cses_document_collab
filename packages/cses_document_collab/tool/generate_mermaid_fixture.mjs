// Reads published Schema factories; writes a Yjs fixture without loading Angular.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
const [packageRoot, desktopRoot] = process.argv.slice(2);
if (!packageRoot || !desktopRoot) throw Error('Usage: node tool/generate_mermaid_fixture.mjs <published-package> <desktop-root>');
const version = JSON.parse(fs.readFileSync(path.join(packageRoot, 'package.json'))).version;
if (version !== '0.11.21') throw Error('Expected published @ccc/blockcraft 0.11.21');
const require = createRequire(path.resolve(desktopRoot, 'package.json'));
const Y = require('yjs');
const source = fs.readFileSync(path.join(packageRoot, 'fesm2022/ccc-blockcraft.mjs'), 'utf8');
const editableStart = source.indexOf('const editableBlockCreateSnapShotFn =');
const editableEnd = source.indexOf('\nclass SchemaManager', editableStart);
const schemaStart = source.indexOf('const MermaidBlockSchema =');
const schemaEnd = source.indexOf('\n/**', source.indexOf('const MermaidTextareaBlockSchema =', schemaStart));
const typographySource = fs.readFileSync(path.join(packageRoot, 'fesm2022/ccc-blockcraft-framework-block-std-typography.mjs'), 'utf8')
  .replace(/^import .*\n/gm, '').replace(/^export \{ INLINE_TYPOGRAPHY_ATTRS \}.*\n/gm, '');
const typography = await import('data:text/javascript;base64,' + Buffer.from(typographySource).toString('base64'));
let index = 0;
const context = vm.createContext({...typography, generateId: () => `mermaid-fixture-${++index}`,
  BlockNodeType$1: {editable:'editable',block:'block'}, MermaidBlockComponent:{}, MermaidTextareaBlockComponent:{},
});
vm.runInContext(source.slice(editableStart, editableEnd) + source.slice(schemaStart, schemaEnd) + '\nglobalThis.schema = MermaidBlockSchema;', context);
const diagram = context.schema.createSnapshot('default', 'flowchart LR\nA[开始]-->B[完成]');
diagram.id='mermaid-1'; diagram.children[0].id='mermaid-source-1';
diagram.props.customDiagram={preserve:true};diagram.children[0].props.customSource='preserve';
diagram.meta.customAudit='preserve';
const nested = context.schema.createSnapshot('text','sequenceDiagram\nAlice->>Bob: 你好');
nested.id='nested-mermaid';nested.children[0].id='nested-source';
const root={id:'fixture-doc',flavour:'root',nodeType:'root',props:{},meta:{},children:[diagram,
  {id:'box',flavour:'callout',nodeType:'block',props:{prefix:'💡'},meta:{},children:[nested]},
  {id:'tail',flavour:'paragraph',nodeType:'editable',props:{},meta:{},children:[{insert:'保留正文'}]},
]};
const doc = new Y.Doc({clientID: 81721});doc.clientID=81721;
const blocks = doc.getMap('blocks');
function insert(snapshot){
 const model = new Y.Map(); blocks.set(snapshot.id,model);
 for(const key of ['id','flavour','nodeType'])model.set(key,snapshot[key]);
 for(const key of ['props','meta']) {const map=new Y.Map();model.set(key,map);for(const [k,v] of Object.entries(snapshot[key]))map.set(k,v);}
 if(snapshot.nodeType==='editable'){const text=new Y.Text();model.set('children',text);text.applyDelta(snapshot.children);}
 else{const children=new Y.Array();model.set('children',children);children.push(snapshot.children.map(c=>c.id));snapshot.children.forEach(insert);}
}
doc.transact(()=>insert(root));
const output=fileURLToPath(new URL('../rust/tests/fixtures/blockcraft-mermaid.update',import.meta.url));
fs.writeFileSync(output,Y.encodeStateAsUpdate(doc));
console.log(JSON.stringify({version,output,bytes:fs.statSync(output).size,diagram:diagram.id,source:diagram.children[0].id}));
