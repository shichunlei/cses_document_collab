# 元数据并发修复复审

日期：2026-10-28。范围为 [上一轮三项 P2 修复](metadata-concurrency-fixes.md)、控制器的业务端口及头部保存结果消费。本轮不修改产品代码或正式测试，只归档复审和隔离探针证据。

## 原问题结论

三项原问题在本轮验证范围内已解决：

1. 读取补丁在开始/结束时清空，只缓存当前读取期间事件；正式测试覆盖首载与已有快照的读取失败后重试，旧名称、图标及封面不会覆盖新 HTTP。
2. 图标与封面均检测同字段冲突，包括远端删除；有冲突时保持远端显示并补读权威结果。补充探针核对相同值/移除回显不多发读取，不同字段更新仍保留。
3. `saving` 保持至旧读取与冲突补读结束，第二次提交被拒绝。关闭会等待在途补读并拒绝迟到结果；写入任务只清理自身引用，正式测试覆盖结束通知同步发起下一次保存。补充探针覆盖旧读取尚未完成时保存冲突、该阶段关闭及补读期间的新远端事件。

未发现本轮修复新增的功能回归，但发现此前遗漏的失败提示问题，不能宣称当前相关代码没有问题。

## 遗漏问题：P2 保存失败提示被冲突补读清除

定位：`lib/src/controller/document_metadata_controller.dart:194–196`，结合 `_load` 开始时 `error = null`；头部 `DocumentHeader._edit` 等待 `save` 后只根据 `controller.error` 展示失败提示，没有消费返回的 false。

复现顺序：本地名称提交等待确认 → 同字段远端名称事件使 `_writeConflict` 为 true → 本地请求因权限/网络等原因失败，catch 设置“头部保存失败，请重试”并返回 false → finally 仍发起冲突补读 → 补读成功但清空 error。最终 save 为 false，页面却没有保存失败提示，用户不能知道草稿未保存。

该控制流在上一轮三项修复前即存在：当时 finally 同样会在 catch 后执行 `refresh()` 并由 `_load` 清空 error。本轮是补充发现，不归因为保存锁或补丁清理修复新引入。

建议把写入失败状态与补读状态分别保留，或补读结束后恢复本轮写入失败提示；不能只因权威读取成功就把失败的本地提交当作成功。若本地写入成功但补读失败，仍应保留补读失败提示及已确认的写入事实。

## 证据与检查

- 正式测试重新执行 `flutter test --no-pub test/document_metadata_controller_test.dart test/document_header_test.dart --reporter expanded`，**41 项通过**；[日志](metadata-concurrency-rereview-tests.log)。
- 隔离探针 **9 项通过、1 项失败**。唯一失败为上述保存错误提示被清空，期望 error 非 null，实际 null；[日志](metadata-concurrency-rereview-probes.log)、[源码文本](metadata-concurrency-rereview-probes.dart.txt)。将源码文本复制为 `/tmp/cses_metadata_recheck_test.dart` 并在根包运行 `flutter test --no-pub /tmp/cses_metadata_recheck_test.dart --reporter expanded` 可复跑。
- 对控制器、控制器测试与头部消费者运行 `flutter analyze --no-pub`，无问题；[日志](metadata-concurrency-rereview-analyze.log)。`git diff --check` 通过。
- 未执行真机、真实 HTTP/在线双端或平台构建；以上结论限定静态分析和可控业务端口下的并发/生命周期验证。
