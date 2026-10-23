import fs from 'node:fs';
import '/System/Volumes/Data/workspace/cses-client/node_modules/@angular/compiler/fesm2022/compiler.mjs';
const bc=await import('/System/Volumes/Data/workspace/cses-client/node_modules/@ccc/blockcraft/fesm2022/ccc-blockcraft.mjs');
const params={root:['root',[]],table:[2,2],image:[{src:'https://example.com/sample.png',wr:100,ar:1.5},undefined,undefined,'图片说明'],shape:['diamond','形状文字'],'text-box':['文本框正文'],'word-art':['艺术文字'],formula:['x^2'],attachment:[{url:'https://example.com/a.pdf',name:'附件',size:123,type:'pdf'}],video:[{url:'https://example.com/a.mp4'}],audio:[{url:'https://example.com/a.mp3',name:'音频'}],bookmark:['https://example.com'],embed:['https://example.com'],'figma-embed':['https://www.figma.com/file/Abcdefghijklmnopqrstuvwxyz/name'],'juejin-embed':['https://juejin.cn/post/demo'],mermaid:['graph LR\nA-->B'],sticker:['sunburst'],column:[[]],columns:[2],'object-group':[{},[]],'placement-layout':[[]]};
const blocks=[],errors=[];
for(const schema of bc.BUNDLED_EDITOR_SCHEMAS){
 if(['root','table-row','table-cell','column','caption','shape-text','mermaid-textarea'].includes(schema.flavour))continue;
 try{blocks.push(schema.createSnapshot(...(params[schema.flavour]??['桌面'+schema.flavour])));}catch(e){errors.push([schema.flavour,e.message]);}
}
let seq=0;
function normalize(block){block.id='desktop-'+(++seq);if(block.nodeType==='root'||block.nodeType==='block')block.children.forEach(normalize);}
for(const b of blocks){
 if(b.flavour==='object-group'){b.props={width:240,height:140};b.children=[bc.ShapeBlockSchema.createSnapshot('ellipse','组合内容')];b.children[0].props.position='10 10';}
 if(b.flavour==='placement-layout'){b.children=[bc.TextBoxBlockSchema.createSnapshot('定位文本',{width:200,height:80,position:'5 5'})];}
 if(b.flavour==='render-unit')b.children=[bc.ParagraphBlockSchema.createSnapshot('内容区域正文')];
 if(b.flavour==='person-card')b.props.frozen={name:'示例人员',department:'示例部门'};
 if(b.flavour==='weather')b.props.frozen={temp:23,condition:'晴',tone:'sunny',location:'示例城市',high:25,low:18};
 if(b.flavour==='date-card')b.props.date='2026-10-23';
}
for(const [flavour,props] of [['task',{taskId:'task-demo',title:'示例任务'}],['task-list',{itemsJson:JSON.stringify([{id:'t1',title:'清单任务',checked:true}])}],['meeting',{meetingId:'meeting-demo'}],['kr-list',{meetingId:'meeting-demo'}],['mind-map',{data:{data:{text:'中心主题'},children:[{data:{text:'分支一'}}]}}]])blocks.push({id:'',flavour,nodeType:'void',props,meta:{},children:[]});
const root=bc.RootBlockSchema.createSnapshot('fixture-root',blocks);normalize(root);
fs.mkdirSync('packages/cses_document_collab/test/fixtures',{recursive:true});
fs.writeFileSync('packages/cses_document_collab/test/fixtures/desktop-json-blocks.json',JSON.stringify(root,null,2)+'\n');
console.log(JSON.stringify({errors,types:blocks.map(b=>b.flavour),nodes:seq}));
