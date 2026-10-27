# 旧有序列表标题JSON导出规则

日期：2026-10-27。接续同轮[完整性核查](report.md)，按用户明确的新规则关闭旧有序列表heading导出P2。

## 最终规则

- `ordered.props.heading=1～6`：导出保留对应H1～H6级别。
- 旧 `heading=7/8/9`：导出移除heading，按普通列表正文处理，保留ordered类型、编号设置、文字/富文本和业务身份；不转换成H6。
- 有序列表以当前段落属性为准，显式改成合法标题或清除heading后，不从旧bc归档恢复旧值。其他不支持的heading值也按无标题处理。
- 规则只作用于有序列表JSON导出。导出不改写当前文档树、原始JSON或共享Yrs属性；普通paragraph旧超范围标题的既有兼容规则保持。

实现位于 `BlockCraftJsonCodec.encodeBlock`：有序列表也读取实时heading字段，再只保留1～6的整数。其他字段仍走既有编码路径；没有修改Rust、FRB、依赖、导出入口或生成文件。

前轮[审计探针](audit-probe-tests.txt)按当时“9应输出6”的契约失败，作为原始核查证据保留；本轮用户将7～9的目标明确为普通正文，该旧探针的断言不再作为当前验收规则。正式回归按本页规则验证。

## 验证

| 项目 | 结果 |
|---|---|
| 新增专项回归 | 13项；修复前[6通过/7失败](ordered-heading-before.txt)，覆盖7/8/9、实时字段更新/清除与整篇JSON往返的失败路径 |
| 修复后专项及标题/JSON关联5文件 | [76通过](ordered-heading-after.txt)，含新增13项；没有失败或跳过 |
| 宿主JSON消费者3文件 | [25通过](ordered-heading-host-tests.txt)，无失败或跳过 |
| 包内修改文件及标题关联静态分析 | [无问题](ordered-heading-analysis.txt) |
| 宿主JSON消费者静态分析 | [无问题](ordered-heading-host-analysis.txt) |
| 格式/差异 | 两个手写Dart文件按120列执行dart format；git diff --check通过 |

专项验证1～9全部级别，并检查order/start/continuePrevious/ms/depth、独立meta/业务字段、中文/Emoji、加粗/字号和人员提及的保留；单块及整篇编码、JSON序列化后重新导入导出稳定，源快照和源节点均不被改写。

本轮没有改原生接口、平台配置或渲染，不新增Android/iOS完整构建、真机、在线双端、重连/并发或服务端ACK验收。原来42块及13/28/1/0统计保持，其他适配缺口保留。

## 版本复核

在桌面项目目录用新临时npm缓存实时查询其配置仓库：latest仍0.11.31，dist SHA1仍 `290e54057395c172887cd5c34973e951ac60c76d`，与本轮已下载发布产物一致。桌面声明/Yarn锁0.11.30、实际安装0.11.21，历史pnpm0.2.78；未升级依赖。

复核对应版本随包技能、MIGRATIONS的段落/列表与编号规则、OrderedBlockSchema及移动端属性包装/编码实现。上游ordered支持heading作为段落属性，删除heading无需改变flavour；本轮7～9降为正文为用户指定的移动端导出兼容规则，不宣称上游自动迁移旧数据。0.11.31的其他版本差异沿用前轮[版本证据](blockcraft-version.json)与待办，本轮指纹及验证见[记录](ordered-heading-validation.json)。
