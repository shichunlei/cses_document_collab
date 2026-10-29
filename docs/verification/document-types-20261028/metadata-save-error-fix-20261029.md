# 冲突补读保留保存失败提示

日期：2026-10-29。延续同一轮元数据并发工作，归档于既有目录；对应 [复审遗漏 P2](metadata-concurrency-rereview.md)，原失败证据保留。

## 实现

控制器记录本轮业务写入错误，在冲突补读时显式传入 `_load(retainedError: ...)`。补读开始、成功或失败都保留该错误，同时仍应用权威快照或远端补丁；写入失败继续返回 false，头部等待保存结束后可以显示现有 SnackBar。

若写入已经确认成功但补读失败，则继续返回已确认的写入结果并展示加载错误。后续独立刷新或新一轮保存仍会清除旧提示，不使保存错误永久残留。保存互斥、任务引用归属和关闭等待顺序保持。

修改文件：控制器、控制器测试及头部 Widget 测试；未修改头部产品 UI、宿主、Rust、生成桥接或依赖，保留原有未提交改动。

## 验证

新增 4 项控制器测试覆盖写入成功/失败与补读成功/失败的组合，核对返回值、错误类型、权威快照、状态释放和后续刷新清错。新增 1 项 Widget 测试通过实际标题提交入口模拟并发远端名称及本地失败，验证补读后仍显示保存失败 SnackBar，且正文保持。

- 修复前执行新增控制器组合测试，2 项通过、2 项失败；失败均为写入错误被成功补读清除或被补读错误覆盖。见 [修复前日志](metadata-save-error-20261029-before.log)。
- 首轮 Widget 用例在保存 Future 未完成时等待所有动画停止，遇到持续保存指示动画而超时；改为按既有用例方式推进有限帧后再模拟响应。[首次执行日志](metadata-save-error-20261029-first-widget-attempt.log) 保留；该调整只涉及测试等待方式。
- 对 3 个修改的手写 Dart 文件执行 `dart format`。
- 修复后运行 `flutter test --no-pub test/document_metadata_controller_test.dart test/document_header_test.dart --reporter expanded`，**46 项全部通过**，包含新增 5 项；[测试日志](metadata-save-error-20261029-tests.log)。
- 对控制器、两份测试及头部消费者运行 `flutter analyze --no-pub`，**无问题**；[分析日志](metadata-save-error-20261029-analyze.log)。最终 `git diff --check` 通过。

本轮不做真机、真实 HTTP/在线双端或平台构建验收，不将历史真机结论作为本轮新证据。
