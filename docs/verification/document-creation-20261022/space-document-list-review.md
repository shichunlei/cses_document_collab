# 创建页空间列表审查

> 后续状态：L1/P2已修复，新增正式回归及验证见[修复记录](space-document-list-p2-fix.md)。下文保留修复前的审查与复现依据。

日期：2026-10-22。范围：空间列表、右上角创建入口及其与已有恢复流程的交互。发现1项P2，未修改业务代码、未暂存或提交。

## L1 / P2：恢复完成后迟到的空间响应覆盖固定创建位置

位置：`example/lib/src/demo/document_creation/document_creation_page.dart:78–86`，关联第158行列表目标选择。

触发顺序：

1. 从文件夹或非默认空间恢复一项已有正式ID的创建，空间列表请求仍在等待。
2. 用户点击右上角“继续完成”，打开流程期间另一路由覆盖创建页。
3. 创建完成，协调器变为completed，页面保留“打开文档”入口。
4. 空间列表此时才返回，默认首项为个人空间；用户返回创建页。

`_load`在响应返回时只检查`coordinator.pending`。此时pending已为false，且`_selected`尚未初始化、`initialTarget`为空，因此回落到列表首项。build同样只在pending时使用操作目标，导致已创建于原文件夹的文档旁边展示个人空间及个人空间文档列表，位置选择还因创建完成而被冻结。

临时Widget复现确认协调器已completed且保留“打开文档”，列表目标预期`restored-folder`，实际`space`。文档真实创建位置及持久化操作未变化，此项是页面上下文错误，不是正文覆盖。

建议：恢复记录读取成功时固定本次页面关联的操作及目标，不仅依赖响应返回时的pending状态。创建完成但尚未导航离开时，列表及冻结的位置展示继续使用该目标；补上空间请求晚于恢复完成、页面被覆盖后返回的回归。

## 验证与其他结论

- 重跑创建协调器/页面、空间Sliver列表、真实Common适配器三个文件，共48项通过，0失败。
- 仓库外追加1项Widget复现，目标空间断言失败，确认L1；原测试文件与业务源码均未修改。
- 当前应用及测试源文件哈希与上一轮74项验证快照一致；未重复运行未变化的原生或平台构建。
- 再次核对客户端getDocList和Java ComplexIdQuery、DocumentQueryHandler、Pagination，id、页码、pageSize、createdAt排序及totalCount推导契约一致；所有者name字段与Java User/IdName契约一致。
- git diff --check通过。真实服务返回及设备展示仍未验收，不将替身测试等同线上联调。

BlockCraft通过桌面配置仓库再次查询latest=0.11.27；桌面声明/Yarn锁定/安装仍为0.11.24/0.11.24/0.11.21。复核随包技能、MIGRATIONS及本轮宿主接口，不升级依赖，41块与13/14/1/13统计保持。

复现输出见[日志](space-document-list-review-probe.txt)。
