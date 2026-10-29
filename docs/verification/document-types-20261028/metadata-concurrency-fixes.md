# 元数据并发问题修复

日期：2026-10-28。对应 [未提交代码审查](pending-changes-review.md) 的三项 P2；历史失败日志与结论保留。

## 实现

- 读取开始和结束时清空本轮远端补丁，只缓存读取期间的事件，失败请求的补丁不再覆盖后续 HTTP 快照；已有视图仍可即时接收远端更新。
- 图标和封面也按当前提交字段检查冲突，包括远端删除。不同字段不会互相触发写入冲突；确认前的同字段不同值使本轮在 ACK 后读取权威快照。
- 保存锁保持到旧读取与冲突补读结束，阻止第二次保存覆盖任务引用；关闭等待整个写入/补读周期，关闭后的迟到快照不回写，保存返回 false。
- 写入任务只清理自身引用，兼容完成通知的监听者同步发起下一次保存，避免旧任务清除新任务。同步更新控制器 DartDoc。

产品改动仅限 `lib/src/controller/document_metadata_controller.dart`，正式回归追加于 `test/document_metadata_controller_test.dart`，保留同文件既有未提交改动。

## 回归范围

新增 8 项用例：首次/已有快照读取失败后重试（2）、图标/封面远端替换或删除的冲突补读（4）、补读期间禁止再保存且关闭等待响应（1）、完成通知同步发起下一轮写入的引用归属（1）。覆盖迟到结果、资源关闭及保存锁，不使用实际网络。

最终检查：

- 两个修改的手写 Dart 文件执行 `dart format`。
- 根包执行 `flutter test --no-pub test/document_metadata_controller_test.dart test/document_header_test.dart --reporter expanded`，**41 项全部通过**，包含新增 8 项；见 [测试日志](metadata-concurrency-fixes-tests.log)。
- 对控制器、控制器测试及头部消费者执行 `flutter analyze --no-pub`，**无问题**；见 [静态分析日志](metadata-concurrency-fixes-analyze.log)。审查时发现的 if 大括号 info 已消除。
- 最终 `git diff --check` 通过。

本轮只涉及 Dart 控制器；未修改或重新验证原生桥接、平台构建与在线双端，不复用历史真机结果宣称本轮验收通过。
