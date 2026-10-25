# H1~H6 改动审查

日期：2026-10-25。审查当前工作区相对 `8957022` 的标题范围改动，包括协同包、AppFlowy fork、Rust、工具及测试。未修改业务实现，也未提交本轮改动。

结论：确认 2 项 P1 和 1 项 P2，当前实现仍有影响旧数据编辑与协议一致性的缺陷。上一轮通过的目标回归没有覆盖这些路径。

后续状态：本页两项P1已在同轮修复并完成真实控制器、原生历史与重开验证，见[修复记录](p1-fixes.md)。以下保留审查时的原始复现结论；P2仍待修复。

## P1：旧标题拆段会被新原生校验拒绝

位置：`packages/cses_document_collab/rust/src/api/paragraph_style.rs:121–122`，关联 `appflowy_block_editor_adapter.dart:1315–1320`、`collab_paragraph_editing.dart:89–110`。

已有 `props.heading=9` 的正文被投影为 H6，但 `paragraph_style` 包装仍保留原值。段中 Enter 总是保留当前样式；段尾设置 `nextParagraphStyle=same` 也走同一路径。该路径通过 `nextProps = {...props}` 将 9 复制到新段落。新段落进入原生初始属性校验，触发 `INVALID_PARAGRAPH_STYLE`。

真实 FRB 探针从旧标题样本读取到 H6 后执行正常拆段，捕获上述原生拒绝。界面已经插入新节点，协同写入却未接受，不能把“打开时可展示”视为旧数据编辑兼容。

建议在新段落/新身份的属性生成边界规范化标题到六级，既保留原块原始值，也保证新块合法；覆盖段中拆分、段尾同型续写与新身份历史恢复。

## P1：截断计数器 key 会改变旧列表分组并写回编号

位置：`packages/cses_document_collab/rust/src/api/blockcraft.rs:100`，关联该文件 `update_ordered_counters` 及 `collab_controller.dart:572–575`。

`ordered_projection` 在生成 `(depth, heading)` 计数器 key 之前执行 `.min(6)`，使旧的 7 级与 8 级编号组变为同一组。两条相同 depth、分别属于 heading=7/8、各自从 1 起始的列表，当前投影输出零基编号 `[0,1]`，旧规则及桌面均为 `[0,0]`。

更重要的是，这不只影响展示：未修改正文而调用 `applyBlockSnapshot(currentBlocks)`，就会生成修复增量，将第二条原始 `order=0` 改为 1，同时原始 `heading=8` 保持不变。真实 Yjs 回读结果见 [修复前后属性](review-ordered-repair.json)。控制器握手后遇到 `needsRepair` 会调用同一修复路径，所以可编辑文档首次同步也可能改写旧编号；这是依据现有控制器路径作出的推论，本轮未连接真实服务。

最新桌面发布实现仍使用未截断的 `normalizeOrderedCounterInteger(block.props.heading)` 分组。移动端提前合并 key 后写回 order，会造成跨端编号含义不一致。

建议保留原始协议值作为旧数据计数器分组依据，将六级裁剪限定于可见级别和明确的新写入；若要迁移分组，需要显式、一致地迁移数据，不能混入握手修复。

## P2：JSON 导出只限制 paragraph，列表 heading 仍可输出 9

位置：`packages/cses_document_collab/lib/src/editor/blockcraft_json_codec.dart:388–406`。

标题裁剪仅在 `kind == 'paragraph'` 分支执行；后续段落字段遍历又直接跳过 `heading`。导入 `flavour=ordered, props.heading=9` 后直接导出，仍得到 `heading=9`。这与本轮“导出只产生六级范围”的契约不一致，也与新原生类型/属性写入校验形成差异。

建议将所有合法使用 heading 的类型纳入一致的导出规范化策略，或明确拒绝超范围导出。增加 ordered 等段落族的往返覆盖，不能只测试 paragraph。

## 其他边界观察

第四个探针发现，独立 `DocumentEditorController` 的原始 `EditorState.apply` 能直接插入 `level=9`；其配置虽限制六级，但通用控制器未安装本地配置事务 guard。本轮新增事务拒绝测试只覆盖 `LocalEditorController`。

这属于原有低层模型 API 与能力配置之间的边界，原控制器本来也未承诺验证所有任意节点属性。因此不单独列为本轮新增缺陷，但后续验收应明确“六级限制”针对受支持命令/导入导出，还是要求任意低层事务也受到强约束。

## 证据与验证范围

- [审查元数据](review-validation.json)：本轮实现与上一轮验证的源码指纹完全一致。
- [探针运行日志](review-probes.txt)：4 个边界探针均暴露其断言差异；其中前三类问题按上述证据确认，低层 API 观察不独立归因。
- [可复现探针源码](review-probe-test.dart.txt)：运行时放在协同包的 `test/` 下，审查结束后归档为证据，未留下默认运行即失败的包测试。
- [夹具生成器](review-fixtures.mjs)：使用桌面已安装 Yjs，生成脱敏旧标题和旧编号组样本；不访问真实业务数据。
- [旧标题样本](review-legacy-heading.update)、[旧编号组样本](review-legacy-ordered.update)、[实际修复增量](review-ordered-repair.update)。
- 重新实时查询 `latest=0.11.30`；桌面声明/Yarn 锁为 0.11.28，安装版为 0.11.21，见 [本轮版本记录](review-version.json)。读取随包技能、迁移及计数器受影响实现，版本组合未变；未升级依赖。
- `git diff --check` 通过。本轮没有重复运行源码完全相同的全部回归，也没有进行完整 App 构建、物理设备或真实在线双端验收；上一轮 193 项 Rust、19 项 AppFlowy、9 项原生、39 项宿主与包内 172 通过/1 项既有失败的结果保持原始含义，不能覆盖本轮新发现。
