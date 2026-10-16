import fs from 'node:fs';
import pathModule from 'node:path';
import {fileURLToPath} from 'node:url';
// Pass the extracted, published @ccc/blockcraft package directory. No installed package is modified.
const packageRoot=process.argv[2];
if(!packageRoot) throw new Error('Usage: node tool/generate_paragraph_oracle.mjs /path/to/extracted/package');
if(JSON.parse(fs.readFileSync(pathModule.join(packageRoot,'package.json'),'utf8')).version!=='0.11.20') throw new Error('Expected published version 0.11.20');
const path=pathModule.join(packageRoot,'fesm2022/ccc-blockcraft-framework-block-std-typography.mjs');
let source=fs.readFileSync(path,'utf8').replace(/^import .*\n/gm,'').replace(/^export \{ INLINE_TYPOGRAPHY_ATTRS \}.*\n/gm,'').replace(/^export \{ .*\};?$/gm,'');
source += '\nexport {normalizeParagraphTextDefaults,resolveNextParagraphStyle,TYPOGRAPHY_FONT_FAMILIES};';
const module=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
const inputs=[null,[],{}, {'t:px':'0x18','t:ls':-.0755}, {'t:fs':'Infinity','t:px':'NaN','t:ls':.5}, {'a:bold':true,'a:italic':false,'a:link':'https://private.test','mentionId':'id','r:insert':'revision','s:color':'#ff0000','t:px':'24.12345678','t:fs':'1.1254','t:ls':-.075,'t:ff':'xingkai'}, {'a:sub':true,'a:sup':true,'s:fontFamily':'KaiTi','s:fontSize':'1.25em','s:letterSpacing':'0.1em','t:ff':'invalid','t:px':4097,'t:fs':.49,'t:ls':.501}, ...module.TYPOGRAPHY_FONT_FAMILIES.map(({id})=>({'t:ff':id}))];
const cases=[];
for(const flavour of ['paragraph','bullet','ordered','todo','blockquote']) for(const heading of [undefined,2]) for(const nextParagraphStyle of [undefined,'same','body']) for(const atEnd of [false,true]) {
 const props={depth:2,textAlign:'center',backColor:'#ffeedd',textDefaults:{'a:bold':true},order:9,start:5,continuePrevious:false,checked:1,...(heading?{heading}:{}),...(nextParagraphStyle?{nextParagraphStyle}:{})};
 cases.push({flavour,props,atEnd,expected:module.resolveNextParagraphStyle(flavour,props,atEnd)});
}
fs.writeFileSync(fileURLToPath(new URL('../test/fixtures/blockcraft-0.11.20-paragraph.json', import.meta.url)),JSON.stringify({version:'0.11.20',source:'fesm2022/ccc-blockcraft-framework-block-std-typography.mjs',normalization:inputs.map(input=>({input,expected:module.normalizeParagraphTextDefaults(input)})),next:cases},null,2)+'\n');
