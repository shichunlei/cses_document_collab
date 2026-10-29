# 文档列表实体字段补齐

日期：2026-10-28。依据用户提供的真实列表结构核对，夹具使用虚构成员、文档及空间身份。本文保留当时拆分统计模型的实现记录；后续已按用户要求[合并行为实体](behavior-merge.md)，当前统一使用DocBehaviorEntity。

## 字段归属与行为

- `DocListEntity`补齐`nodeType`、`updater`和顶层`behavior`，并传递、解析及输出父类已有`banner`。
- `behavior.comment`由新增`DocNodeBehaviorEntity`显式解析，数值num转int；缺失/null统计外壳保留null，空对象或comment缺失/null按0，未知统计键保留。通用Behavior使用commentCount及混合个人状态，不符合本接口原始协议，故不直接复用；现有DocBehaviorEntity仅表达localUser的个人布尔状态，同样不能代替顶层统计。
- `nodeType`和`updater`归入公共列表实体，目录和搜索结果通过继承复用，去掉原有同名字段重复声明；构造参数名称继续兼容。
- 列表、目录和搜索结果通过`super.toJson()`复用父级输出，避免封面及后续父级字段遗漏；目录沿用nodeType显式null输出，其他新增可空字段省略null。
- 目录树`fromEntity`和`copyWith`保留封面、统计、业务更新人及openedAt；封面空对象仍解析为显式空封面并输出{}。顶层read与localUser.behavior.read分别保留，不相互覆盖。
- owner/creator/editor/updater复用CompanyStructureBean解析，完整读取公司、部门、组织、人员身份及isUser/user兼容字段；不修改其跨业务的精简toJson合同。icon:{}沿用无有效图标语义，不制造图标值。
- 新统计类型通过doc模块既有公开入口导出；未修改共享协同包、Demo、BlockCraft正文或原生协议。

## 关键源码

- [公共列表实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_list.dart)
- [统计与个人行为实体（已合并）](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_local_behavior.dart)
- [目录和节点复制](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_folder.dart)
- [搜索结果](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_search_result.dart)
- [完整样例测试](../../../../cses/cses.saas/test/modules/doc/document_list_fields_test.dart)

## 验证

- 修改前3项反例分别确认列表遗漏nodeType、目录/搜索遗漏顶层统计，见[修复前](list-fields-before.log)。
- 运行`flutter test --no-pub test/modules/doc/document_list_fields_test.dart test/modules/doc/document_type_routing_test.dart test/modules/doc/document_api_use_cases_test.dart`，**62项通过**，见[测试日志](list-fields-tests.log)。包含完整样例、精确输出Map、三类列表解析、缺失/null/空对象、num转换、错误外壳、未知统计、独立read状态、目录转换与重命名复制，以及既有类型分流/API消费者。
- 对5个修改/新增源码和1个测试运行dart format及flutter analyze，静态检查无问题，见[格式日志](list-fields-format.log)、[静态检查](list-fields-analyze.log)。
- 检索nodeType/updater声明及构造参数，确认只有公共列表保存字段，子类使用super；两个仓库git diff --check通过，记录链接存在检查通过。

建议后续在真实列表页面核对非零评论数量、editor与updater不同人，以及空/有封面记录；本轮没有新增真机、真实服务或完整App构建验收。保留全部既有工作区和暂存区改动，未提交或暂存本次修改。
