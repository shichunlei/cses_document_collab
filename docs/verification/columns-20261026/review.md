# columns / column 改动审查（2026-10-26）

后续：R1/R2已在同日修复，见[修复与验证](fixes.md)。以下结论及失败证据保留审查当时的状态。

结论：发现2项确定缺陷（1项P1、1项P2），均未修复。本轮只审查与归档证据，没有修改产品源码、安装应用或更新桌面依赖。开始时已有的AppFlowy依赖声明和日成果JSON不属于本次审查范围。

## R1 [P1] 按词退格绕过列边界保护，合并并持久化相邻列正文

位置：`packages/cses_document_collab/lib/src/editor/document_editor_view.dart:403`（命令装配；新列渲染注册在482～483行）。

在第二列的首个普通段落开头，执行Ctrl+Backspace（Mac对应Alt+Backspace）。目前装配只在普通 `backspace, shift+backspace` 路径加入 `collabBlockBackspaceCommand`；标准 `deleteLeftWordCommand` 仍原样启用，在偏移0时直接调用AppFlowy的 `backspaceCommand.execute`，绕过 `isProtectedCalloutBoundary`。标准命令会向前查找上一可编辑节点，跨到前一列，合并正文并删除当前段落。

独立适配器反例的期望为左“第一列”、右“第二列”，实际为左“第一列第二列”、右段落已不存在。真实发布夹具经过FRB/Yrs原生历史层后，同样得到左“第1列正文第2列正文”、右段落不存在；原生接受了这一共享结构变化，并非只有界面显示异常。这是折叠光标的单次退格，并不依赖文档中已列为待办的跨列范围选区。

应将按词退格在段首的回退接入相同边界/列表保护，或统一约束跨容器的段落合并，保留同列正常按词删除。新增普通/列表首段、首列/后续列及真实原生持久化回归。

## R2 [P2] 旧分栏草稿导出丢失列宽、列数和列索引

位置：`packages/cses_document_collab/lib/src/editor/blockcraft_json_codec.dart:496–500`。

原有已落盘的 `snapshot-columns` / `snapshot-column` 把原始属性保存在 `bc.p:*`，没有新节点的 `cses_resource` / `cses_columns_*` 字段。新导出逻辑按解析后的 `kind` 无条件进入分栏覆盖路径，先删除 `columnCount`、`columnWidths`、`columnIndex`，再合并 `readCollabColumns()` 的空结果。因此保留旧渲染入口仍不足以保证旧稿交换兼容。

反例按此前真实落盘结构构造、序列化并重新打开旧树，然后直接导出JSON，无需编辑：期望 `{columnWidths: [30,70], columnCount: 2, columnIndex: 0}`，实际三个字段全部缺失。重新导入后原30/70比例会回落为均分，列布局数据已丢失。

应区分旧 `snapshot-*` 与正式 `columns/column` 节点；仅对具有正式投影的节点覆盖布局字段，旧树保留其 `bc.p:*` 属性。不要对所有空投影直接回填原属性，以免复活正式节点中已经显式清除的字段。

## 本轮验证

- 重新通过桌面配置仓库查询 `latest=0.11.30`。桌面声明/Yarn为0.11.30，安装0.11.17，历史pnpm0.2.78；组合未变。安装/发布包随包技能和MIGRATIONS指纹与实施轮次一致；复读选区/范围输入迁移说明、块指南、删除命令及受影响移动实现，未声明桌面升级。见 [review-validation.json](review-validation.json) 和原 [版本证据](blockcraft-version.json)。
- 6个独立探针：3通过、3失败；三个失败分别是R1的适配器与真实FRB复现，以及R2的旧稿导出复现。正确行为断言失败，完整输出保留于 [review-probes-output.txt](review-probes-output.txt)。
- 已排除的相邻场景：向前Delete在本探针中没有跨列；空列纯预览没有插入按钮；真实删除两列中的一列后，连续三轮原生撤销/重做结构有效。这些通过不覆盖上述两个反例。
- 既有分栏/原生15项全部通过；Rust分栏3项全部通过，见 [既有Flutter回归](review-existing-tests.txt) 和 [Rust回归](review-rust-tests.txt)。未重跑全包、平台构建、物理设备或真实在线双端；实施轮次的通过记录仍保留其原有范围。
- 本轮检查产品源码指纹与实施轮次28个来源/夹具指纹一致，确认没有修产品实现。`git diff --check`通过。临时测试从默认test目录移出，保存为 [review-probes.dart](review-probes.dart)，避免把预期失败的审查探针混入正常测试目录。

复现时，从`packages/cses_document_collab`目录将归档探针复制到`test/columns_review_probe_test.dart`，执行`flutter test --no-pub test/columns_review_probe_test.dart --timeout 30s`。探针依赖该包已构建的macOS调试动态库，缺库失败；完成后删除临时副本，保留归档源和输出。

两块继续部分支持，42及13已适配/28部分支持/1结构支持/0未适配统计保持。此次审查不关闭既有拖拽、跨列完整语义、HTML/Markdown和设备/真实在线待办；上述R1/R2另外作为已确认缺陷列出。
