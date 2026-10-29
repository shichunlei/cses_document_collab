# 公共行为实体统一解析

日期：2026-10-28。用户明确DocBehaviorEntity不区分使用位置，全部字段可解析，解析不到时使用默认值。本文保留当时统一解析且暂留扩展字段的实现记录；后续按用户要求删除扩展保留逻辑，当前以[仅保留五字段](behavior-five-fields.md)为准。

## 实现

- 删除fromNodeJson入口、node模式参数及个人/统计序列化开关；列表、目录、搜索统一调用DocBehaviorEntity.fromJson。
- read/liked/subscribe/favorite统一解析为布尔值，缺失、null或类型不符时false；comment为有限num时转int，缺失/null、非数值或非有限值时0。
- 构造器与toJson同样统一：始终输出五个已知字段，不按输入是否包含某键选择输出。未知扩展字段继续保留。
- behaviorFromJson只兼容动态/可空外壳并转交同一解析；非法外壳返回默认实体，没有独立场景规则。
- 父级实体是否保留null的可空behavior外壳沿用既有合同；一旦解析为DocBehaviorEntity，字段及默认规则完全相同。顶层/个人位置可分别持有实例，但不产生不同解析类型。
- 此前为保留不同JSON形态增加两个入口和输出开关，超出了用户希望的公共实体职责；本轮移除这些规则，并将统一解析/默认值约定记录在模块CLAUDE，避免再次按场景拆分。

## 验证

- 四组目标回归**69项通过**：公共实体、完整列表/精简搜索、文档类型分流和业务API消费者，见[最终测试](behavior-common-tests.log)。覆盖空/部分/完整输入、缺失/null、错误类型、非有限数值、未知扩展以及完整五字段精确输出。
- 8个修改或直接关联文件flutter analyze无问题；6个实际修改Dart文件已format，见[静态检查](behavior-common-analyze.log)、[格式日志](behavior-common-format.log)。
- 首轮68通过/1失败源于搜索精确序列化期望未含当前继承模型的description:null；同步明确期望后69项通过，不移除断言或修改该字段实现。首轮[日志](behavior-common-first-tests.log)保留。
- SaaS运行源码及测试中无fromNodeJson、旧模式参数和输出开关；两个仓库git diff --check通过，记录相对链接检查通过。

未改旧统计类型删除结果或公开导出，不改用户原有暂存区，不提交本次修改。未新增真机、完整App构建或真实服务验收。

[公共行为实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_local_behavior.dart)；[默认值专项测试](../../../../cses/cses.saas/test/modules/doc/doc_behavior_entity_test.dart)。
