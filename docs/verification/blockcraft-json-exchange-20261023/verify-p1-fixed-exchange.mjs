// Validate mobile editing artifacts against the installed desktop model and its real host task schema.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import '/System/Volumes/Data/workspace/cses-client/node_modules/@angular/compiler/fesm2022/compiler.mjs';
import * as bc from '/System/Volumes/Data/workspace/cses-client/node_modules/@ccc/blockcraft/fesm2022/ccc-blockcraft.mjs';
import * as Y from '/System/Volumes/Data/workspace/cses-client/node_modules/yjs/dist/yjs.mjs';

const desktop = '/System/Volumes/Data/workspace/cses-client';
const require = createRequire(`${desktop}/package.json`);
const ts = require('typescript');
const directory = new URL('.', import.meta.url);
const taskPath = `${desktop}/packages/docs/src/editor/embedded-references/task-card/index.ts`;
const taskSource = fs.readFileSync(taskPath, 'utf8');
const ast = ts.createSourceFile(taskPath, taskSource, ts.ScriptTarget.Latest, true);
const declaration = ast.statements.filter(ts.isVariableStatement)
  .flatMap(statement => [...statement.declarationList.declarations])
  .find(declaration => declaration.name.getText(ast) === 'TaskCardBlockSchema');
assert(declaration?.initializer);
// Only the Angular component reference is substituted: no component is mounted in this model test.
const taskSchema = new Function('BlockNodeType', 'generateId', 'DlTaskCardBlockComponent',
  `return (${declaration.initializer.getText(ast)});`)(bc.BlockNodeType, bc.generateId, class TaskComponentStub {});
const schemas = new bc.SchemaManager([...bc.BUNDLED_EDITOR_SCHEMAS, taskSchema]);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const results = [];
for (const name of ['p1-fixed-heading-help.json', 'p1-fixed-quote-help.json', 'p1-fixed-todo-tab.json']) {
  const bytes = fs.readFileSync(new URL(name, directory));
  const snapshot = JSON.parse(bytes);
  const document = new Y.Doc();
  const blocks = document.getMap('blocks');
  let count = 0;
  function install(block, parent) {
    const schema = schemas.get(block.flavour);
    assert.equal(block.nodeType, schema.nodeType);
    if (parent) assert(schemas.isValidChildrenForInstance(block.flavour, parent.flavour, parent.meta));
    if (block.flavour === 'task') {
      const factory = taskSchema.createSnapshot({id: block.props.taskId, title: block.props.title});
      assert.deepStrictEqual(block.props, factory.props);
      assert.equal(block.props.taskId, 'task-demo');
    }
    const container = block.nodeType === 'root' || block.nodeType === 'block';
    if (container) block.children.forEach(child => install(child, block));
    assert(!blocks.has(block.id), `duplicate id ${block.id}`);
    blocks.set(block.id, bc.native2YBlock({...block, children: container ? block.children.map(child => child.id) : block.children}));
    count++;
  }
  install(snapshot);
  const model = new bc.BlockModelGraph({yBlockMap: blocks});
  model.build(snapshot.id);
  const exported = bc.BlockCraftDoc.prototype.exportSnapshot.call({model, rootId: snapshot.id});
  assert.deepStrictEqual(exported, snapshot);
  model.destroy();
  document.destroy();
  results.push({file: name, sha256: digest(bytes), blocks: count, schemaAndModel: 'passed'});
}
const result = {date: '2026-10-23', status: 'passed', installed: '0.11.17', typescript: ts.version,
  taskSchema: {source: taskPath, sha256: digest(taskSource), component: '仅Angular组件引用替身，Schema对象与createSnapshot来自实际桌面源声明'}, results,
  limits: ['未操作桌面窗口/系统文件框', '0.11.30只做静态核对，未安装或运行新版', '未新增真机/iOS/线上双端验收']};
fs.writeFileSync(new URL('p1-fixes-desktop-model-validation.json', directory), `${JSON.stringify(result, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(result)}\n`);
