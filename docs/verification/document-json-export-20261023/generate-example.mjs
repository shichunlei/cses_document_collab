// 使用本机桌面实际安装的 Schema 与模型导出方法生成虚构示例。
import fs from 'node:fs';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import '/System/Volumes/Data/workspace/cses-client/node_modules/@angular/compiler/fesm2022/compiler.mjs';
import * as bc from '/System/Volumes/Data/workspace/cses-client/node_modules/@ccc/blockcraft/fesm2022/ccc-blockcraft.mjs';
import * as Y from '/System/Volumes/Data/workspace/cses-client/node_modules/yjs/dist/yjs.mjs';

const folder = fileURLToPath(new URL('.', import.meta.url));
const timestamp = Date.parse('2026-10-23T09:00:00+08:00');
const heading = bc.ParagraphBlockSchema.createSnapshot('项目进展', { heading: 1 });
heading.id = 'heading-demo';
const paragraph = bc.ParagraphBlockSchema.createSnapshot([
  { insert: '今天完成了' },
  { insert: '文档导出', attributes: { 'a:bold': true, 's:color': '#1677ff' } },
  { insert: '，请 ' },
  { insert: { mention: '张三' }, attributes: { mentionId: 'user-demo', mentionType: 'user' } },
  { insert: ' 帮忙检查。' },
]);
paragraph.id = 'paragraph-demo';
const todo = bc.TodoBlockSchema.createSnapshot('补充导出说明');
todo.id = 'todo-demo';
todo.props.created = timestamp;
const image = bc.ImageBlockSchema.createSnapshot(
  { src: 'https://example.com/demo.png', wr: 100, ar: 1.5 },
  undefined, undefined, '示例图片（虚构地址）',
);
image.id = 'image-demo';
image.children[0].id = 'caption-demo';
const divider = bc.DividerBlockSchema.createSnapshot();
divider.id = 'divider-demo';
const root = bc.RootBlockSchema.createSnapshot('root-demo', [heading, paragraph, todo, image, divider]);
root.meta.createdTime = timestamp;
root.meta.lastModified = { time: timestamp, user: null };

const yDoc = new Y.Doc();
const yBlockMap = yDoc.getMap('blocks');
// 底层协同图保存子块 ID，模型导出再递归恢复为嵌套块。
function install(snapshot) {
  const container = snapshot.nodeType === 'root' || snapshot.nodeType === 'block';
  if (container) snapshot.children.forEach(install);
  yBlockMap.set(snapshot.id, bc.native2YBlock({
    ...snapshot,
    children: container ? snapshot.children.map(child => child.id) : snapshot.children,
  }));
}
install(root);
const model = new bc.BlockModelGraph({ yBlockMap });
model.build(root.id);
const exported = bc.BlockCraftDoc.prototype.exportSnapshot.call({ model, rootId: root.id });
assert.deepStrictEqual(exported, root);
assert.deepStrictEqual(JSON.parse(JSON.stringify(exported)), root);
fs.writeFileSync(`${folder}example.json`, `${JSON.stringify(exported, null, 2)}\n`);
model.destroy();
yDoc.destroy();

const artifact = fs.readFileSync('/private/tmp/ccc-blockcraft-0.11.23.tgz');
const integrity = `sha512-${createHash('sha512').update(artifact).digest('base64')}`;
assert.equal(integrity, 'sha512-hGuC0Ank4stAQqbgfVdTYZaKtTi1dOHopT0Bt1YYQqleHkPBsFiXy6mnwf3E2OpEfcZ3UQaUhKeShArMuOtabw==');
const version = JSON.parse(fs.readFileSync('/System/Volumes/Data/workspace/cses-client/node_modules/@ccc/blockcraft/package.json')).version;
const verification = {
  date: '2026-10-23', desktopInstalled: version,
  desktopDeclared: '0.11.28', desktopYarnLocked: '0.11.28', historicalPnpmLocked: '0.2.78',
  registry: 'http://npm.runtongqiuben.com/', latestReturnedThisRun: '0.11.23',
  latestArtifactIntegrity: integrity,
  checks: ['安装版Schema生成虚构块', '生产模型exportSnapshot与输入树一致', 'JSON编码解码一致', '0.11.23发布压缩包SHA-512与仓库返回一致'],
  limits: ['未操作桌面UI下载', '未验证JSON文件导入入口', '未验证设备/HTTP/在线协同', '未升级依赖或扩展移动端适配状态'],
};
fs.writeFileSync(`${folder}validation.json`, `${JSON.stringify(verification, null, 2)}\n`);
console.log(JSON.stringify({ status: 'passed', example: `${folder}example.json`, desktopInstalled: version, latestArtifactIntegrityVerified: true }));
