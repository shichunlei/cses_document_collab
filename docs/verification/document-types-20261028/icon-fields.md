# 文档图标仅保留明确字段

日期：2026-10-28。按用户要求移除DocIconEntity的_extraFields，仅保留type/value解析和输出。

- 删除未知字段状态、收集/冻结逻辑和序列化展开；fromJson直接构造type/value。toJson仅输出两个键，null仍显式输出，既有移除语义不变。
- iconFromJson保留可用性校验，校验后直接使用type/value构造，不遍历、复制或保留其他输入键；未知键及非字符串键忽略。
- 保留emoji/svg/image展示Getter及已知字段的类型校验合同；空icon和空value仍无可展示图标。
- 同步实体DartDoc、模块CLAUDE及API/详情/元数据适配测试。输入保留plugin等反例，精确断言读写结果只有type/value；增加图标写入回归，确认未知键不进入业务修改参数。

验证：目标4组回归**66项通过**，见[测试日志](icon-fields-tests.log)；实际修改的4个Dart文件已format且flutter analyze无问题，见[格式日志](icon-fields-format.log)、[静态检查](icon-fields-analyze.log)。源实体无_extraFields残留，活动模块文档无图标未知字段保留承诺；两个仓库git diff --check及记录链接检查通过。

覆盖未知键混合、仅未知键、非字符串键、缺失/null、空value、错误type、完整请求参数、元数据读取/写入与权限守卫。未提交或修改已有暂存区，未新增真机、真实服务或完整App构建验收。

[图标实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_info.dart)；[读写适配回归](../../../../cses/cses.saas/test/modules/doc/collaboration/doc_collab_metadata_adapter_test.dart)。
