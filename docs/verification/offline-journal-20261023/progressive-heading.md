# 标题菜单逐级展开

2026-10-23按用户要求恢复H1～H3初始入口，选择H3再出现H4，继续依次到H6；重新打开按当前标题恢复，进入普通正文重置。第一阶段[宿主34项](progressive-heading-host-verified-tests.txt)及[共享菜单33项](progressive-heading-package-tests.txt)通过，双层分析与[Android构建](progressive-heading-android-build.txt)通过，见当时的[快照记录](progressive-heading.json)。

用户随后要求离线与协同采用同一实现，因此当前默认规则已统一为所有编辑器逐级展示，通过同一配置显式控制是否直接展开。第一阶段只在宿主开启、纯文字沿用原预设的中间状态不再是最终目标；当前实施、全量测试和产物以[统一编辑器记录](shared-editor.md)为准。非连续级别会跳过禁用项，保持已启用的标题可达。

[修复前反例](progressive-heading-before.txt)确认H4提前出现；[目标首轮](progressive-heading-host-tests.txt)和[次轮](progressive-heading-host-final-tests.txt)分别因窄屏懒加载中未滚动到旧按钮和重开的H6项而失败，改为验证下一可用级别、未披露项及滚动到真实目标，最终34项通过。旧失败保留，不修改产品布局来迁就断言。本轮没有新增真机或在线验收。

上游latest已重新查询为0.11.29，声明/Yarn锁0.11.28、安装0.11.17、历史pnpm0.2.78。已验证发布tarball的sha512并读取新版本随包L0、MIGRATIONS、文字/块工具栏技能及发布实现。0.11.28→0.11.29实现变化仅涉及图片插入后的gap光标，文字格式与标题菜单相关技能未变；见[发布实现差异](progressive-heading-upstream-diff.txt)。该图片行为保留待移动端同步/验收，未升级桌面或移动依赖。
