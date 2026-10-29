# 文档行为实体合并

日期：2026-10-28。按用户要求将DocNodeBehaviorEntity合并进已有DocBehaviorEntity；本轮只修改SaaS行为模型及直接消费者。本文保留早期按场景保留JSON形态的实现记录；用户后续明确要求不区分场景，当前实现与验证以[公共统一解析](behavior-common.md)为准。

## 实现与兼容

- DocBehaviorEntity统一承载read、liked、subscribe、favorite和comment；节点统计与localUser个人状态使用该类的不同实例，不共享可变状态。
- 保留原个人构造器及fromJson/behaviorFromJson。未提供comment时读取为0且维持原有四布尔输出，显式comment（包括0）可一并输出。
- 同一实体新增fromNodeJson入口，供列表/目录/搜索的顶层behavior使用：空对象/comment缺失或null按0，num转int，未知扩展字段保留；纯统计序列化保持comment及扩展，不新增个人布尔键。
- 所有原DocNodeBehaviorEntity字段/解析/测试统一改用DocBehaviorEntity；删除旧源文件和公开导出，保留既有doc_local_behavior.dart路径及公开入口。没有增加旧名别名或转发文件。
- 保留已有个人行为消费者的构造语义，文档类型分流、成员、列表封面等合同不变。同步模块CLAUDE与历史记录源链接；历史报告仍保留当时拆分实现的结论，并明确指向本合并记录。

## 验证

- 目标四组回归：`flutter test --no-pub test/modules/doc/doc_behavior_entity_test.dart test/modules/doc/document_list_fields_test.dart test/modules/doc/document_type_routing_test.dart test/modules/doc/document_api_use_cases_test.dart`，**69项通过**，见[目标日志](behavior-merge-target-tests.log)。新增4项覆盖同类型不同实例、个人构造/空外壳输出、节点统计/混合行为/未知扩展、错误字段拒绝。
- 9个修改或直接关联文件的flutter analyze无问题，7个实际修改Dart文件已format，见[静态检查](behavior-merge-analyze.log)、[格式日志](behavior-merge-format.log)。
- 扩大到文档模块时为182通过/1失败，失败是未修改的doc_creation_target_review_test.dart分页用例，scrollUntilVisible报Too many elements；对应页面只读取文档id/name/time而非行为字段。随后未改该页面或测试，单独复跑其3项全部通过。保留[扩大检查](behavior-merge-module-tests.log)和[单独复核](behavior-merge-pagination-recheck.log)，不把首次模块检查表述为同次全量通过。
- SaaS运行源码、测试、当前模块文档及jqdl消费者检索无旧类名/路径；旧源文件已从工作区删除。两个仓库git diff --check和本记录相对链接检查通过。

原有暂存区保持未动；旧文件此前已被暂存为新增，本次删除仅体现在工作区，未代替用户更新暂存区。未提交本次修改，未新增真机、真实服务或完整App构建验收。

## 源码

- [合并后的行为实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_local_behavior.dart)
- [节点统计使用点](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_list.dart)
- [专项回归](../../../../cses/cses.saas/test/modules/doc/doc_behavior_entity_test.dart)
