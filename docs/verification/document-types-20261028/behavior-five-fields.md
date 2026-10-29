# 公共行为实体仅保留五个字段

日期：2026-10-28。按用户要求删除DocBehaviorEntity的_extraFields及相关逻辑，只保留五个字段的统一解析和默认值。

- 删除扩展字段状态、_knownKeys、未知字段收集/复制、序列化展开和仅用于这些初始化的私有构造器；fromJson直接调用公共构造器。
- 仅保存/输出read、liked、subscribe、favorite、comment。布尔默认false，comment默认0，有限num转int；缺失、null或类型不匹配仍使用默认值。未知输入键直接忽略。
- 同步公共实体和列表测试：输入保留未知字段作为反例，精确断言输出只有五个字段；缺省、错误类型、非有限数值、混合输入及列表/搜索消费者保持覆盖。
- 更新模块CLAUDE及DartDoc。其他实体的meta、封面扩展等既有协议不属于本轮删除范围，保留未动。

验证：四组目标回归**69项通过**，见[测试日志](behavior-five-fields-tests.log)；实际修改的3个Dart文件已format，目标flutter analyze无问题，见[格式日志](behavior-five-fields-format.log)、[静态检查](behavior-five-fields-analyze.log)。源文件检索无_extraFields、_knownKeys或旧私有构造器残留，两个仓库git diff --check通过，记录链接有效。

边界已验证：未知字段单独输入、未知字段与合法字段混合、空对象、缺失/null、错误类型及非有限数值。未提交或修改已有暂存区；本轮未新增真机/完整App构建/真实服务验收。

[公共行为实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_local_behavior.dart)；[专项测试](../../../../cses/cses.saas/test/modules/doc/doc_behavior_entity_test.dart)。
