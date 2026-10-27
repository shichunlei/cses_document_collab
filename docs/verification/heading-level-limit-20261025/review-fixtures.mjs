import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
const require=createRequire('/Users/shichunlei/workspace/cses-client/package.json');
const Y=require('yjs');
const root=process.cwd();
const output=path.join(root,'docs/verification/heading-level-limit-20261025');
const baseline=fs.readFileSync(path.join(root,'rust/tests/fixtures/blockcraft-basic.update'));
const heading=new Y.Doc();
Y.applyUpdate(heading,baseline);
heading.transact(()=>{
 const props=heading.getMap('blocks').get('p1').get('props');
 props.set('heading',9);props.set('nextParagraphStyle','same');
});
fs.writeFileSync(path.join(output,'review-legacy-heading.update'),Y.encodeStateAsUpdate(heading));
heading.destroy();
const ordered=new Y.Doc();
Y.applyUpdate(ordered,baseline);
ordered.transact(()=>{
 const blocks=ordered.getMap('blocks');const rootBlock=blocks.get('fixture-doc');
 for(const id of [...blocks.keys()])if(id!=='fixture-doc')blocks.delete(id);
 const children=rootBlock.get('children');children.delete(0,children.length);
 for(const [index,level] of [7,8].entries()){
  const id=`ordered-${index}`;const b=new Y.Map();b.set('id',id);b.set('flavour','ordered');b.set('nodeType','editable');
  const props=new Y.Map();props.set('heading',level);props.set('depth',0);props.set('order',0);b.set('props',props);b.set('meta',new Y.Map());b.set('children',new Y.Text('Item'));
  blocks.set(id,b);children.push([id]);
 }
});
fs.writeFileSync(path.join(output,'review-legacy-ordered.update'),Y.encodeStateAsUpdate(ordered));
ordered.destroy();
