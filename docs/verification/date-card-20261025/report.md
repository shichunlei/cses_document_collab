# 日期卡片移动端正式接入（2026-10-25）

移动端现在可通过“添加块→常用→日期卡片”插入正式`date-card`，并可配置键盘直达入口。
日期在插入时定格为本地`YYYY-MM-DDTHH:mm`，重新打开、同步或修改外观不会刷新日期。
已有桌面日期卡片通过正式协同或JSON导入时使用同一原生组件，不再仅显示一行简化日期。

## 实施范围

- `EditorBlock.dateCard`控制块能力，`EditorKeyboardToolbarItem.dateCard`控制直达入口；默认离线目录由25种增加到26种。
- 根级、已适配高亮容器中的日期卡片作为无Delta、无子块的void节点投影；结构异常的日期节点继续按不透明块保护。
- 原生展示支持台历、方牌、长卷、行签、票根、邮戳、翻页牌、报头、页边签、对开日期、胶囊和双轨，支持`full/noWeek/min`显隐。
- 公共更多菜单提供日期设置、锁/授权解锁、正式段落链接、下方插入和删除；后置正文行首退格可删除卡片。锁标复用卡片外框定位，不重复绘制装饰层锁标。
- 设置复用公共居中弹窗、分段选择器和颜色选择器。仅在本地暂存草稿，取消不写入；应用将变化字段合为一次事务/历史。切换样式调整默认固定框，切换格式保留宽度并调整高度。
- 常用字体、12种样式各自的三层字号、文字/背景/边框色及九种边框外观使用正式`ff/fs*/fg/bg/bc/bw`。隐藏层级的字号保留，恢复当前样式字号及默认颜色不影响其他样式或日期。
- 单字段历史使用稳定块身份重定位；远端重排后撤销仍命中原卡片，未修改的共享属性不重放。撤权、锁后解锁、节点替换或远端属性变化不会重新激活旧设置草稿。
- Rust接通正式flavour、void校验、属性投影和显式补丁，不新增FRB公开签名。未知props/meta保留；显式非法属性/正文/URL写入在事务前拒绝。
- JSON导入创建正式日期节点；导出使用实时独立字段，清除颜色等属性后不会从旧`bc.p:*`字段复活。旧`snapshot-date-card`展示也复用日期组件。

本轮保留开始前已有的根`pubspec.yaml`版本改动，没有提交Git或修改桌面依赖。

## BlockCraft版本核对

在桌面项目`cses-client`使用其`.npmrc`配置仓库实时查询，latest为**0.11.30**。
首次沙箱查询因本地代理连接权限失败；在获准执行的同一查询中取得实际仓库结果。
桌面根声明和Yarn锁为**0.11.28**，实际安装为**0.11.21**；历史pnpm锁仍为0.2.78，未升级。

读取三版随包L0、日期块指南、MIGRATIONS及Schema/样式/字号实现；相关契约和实现片段指纹相同。
0.11.30发布包SHA1与实时dist元数据一致。版本值、片段哈希及差异证据见[blockcraft-version.json](blockcraft-version.json)。
其他上游版本差异继续沿用适配表的待同步清单，本轮不声明全版本兼容。

正式Yjs与JSON夹具来自发布版Schema工厂和样式声明，生成入口为
[generate_date_card_fixture.mjs](../../../packages/cses_document_collab/tool/generate_date_card_fixture.mjs)。
固定Yjs clientID和顺序用于重现，夹具包含12样式、嵌套卡片、异常子树及未知属性/元数据。

## 验证结果

| 验证 | 结果 | 证据 |
|---|---|---|
| 日期块、真实FRB/原生历史/SQLite、JSON往返 | 18项通过 | [core-tests.log](core-tests.log) |
| 锁定后解锁的旧草稿仍失效 | 1项通过；与上一组不同用例 | [lock-epoch-test.log](lock-epoch-test.log) |
| 配置、键盘菜单、分割线与分页符关联回归 | 77项通过，1项既有失败 | [related-tests.log](related-tests.log) |
| 日期卡片配置入口/直达插入与撤销专项 | 2项通过；属于关联组重跑子集，不累加 | [direct-menu-tests.log](direct-menu-tests.log) |
| 改动前源码独立基线 | 复现同一工具栏既有失败 | [baseline-toolbar-failure.log](baseline-toolbar-failure.log) |
| Rust全量 | 197项通过，无失败或跳过 | [rust-tests.log](rust-tests.log) |
| Rust fmt/check、宿主原生库重建 | 通过；vendor/yrs保留既有编译警告 | [rust-format.log](rust-format.log)、[rust-check.log](rust-check.log)、[native-build.log](native-build.log) |
| 所属包目标静态分析 | 17个目标通过，无诊断 | [package-analyze.log](package-analyze.log) |
| 宿主lib/test静态分析 | 通过，无诊断 | [host-analyze.log](host-analyze.log) |
| 宿主今日导向JSON转换/编辑/完整性 | 25项通过 | [host-tests.log](host-tests.log) |
| Android最终源码调试构建 | 通过，包含arm64-v8a/armeabi-v7a/x86_64原生库 | [android-build.log](android-build.log) |
| JS生成器语法、相关链接与最终diff检查 | 通过 | [validation.json](validation.json)中的产物/源码指纹及本轮命令 |

核心用例覆盖新建日期定格、锁写保护、字段并发、未知数据保留、独立历史、远端重排/属性冲突、取消/单次应用、撤权恢复、锁定再解锁、JSON清除字段、正式和离线SQLite重开。
窄屏布局覆盖280逻辑像素、1.0/2.2倍系统字号下12×3样式/格式组合。
原生中文字体现实渲染见[12样式预览](date-card-gallery.png)，已目视检查；这是Flutter测试截图，不代替真机。

唯一关联失败为`menu choices cannot reenable disabled block and format capabilities`，断言工具栏隐藏但实际存在。
在`/private/tmp/date-card-baseline`中恢复本轮所有已跟踪Dart文件的HEAD版本、使用原测试并独立解析包路径后，同一断言仍失败。
没有修改该断言或无关的工具栏能力行为以获得通过。本轮迭代发现并修复的重复GlobalKey、邮戳大字溢出，以及日期展示拆分后的旧文本定位均已由最终核心回归覆盖。

Android产物：`build/app/outputs/flutter-apk/app-debug.apk`。APK、各架构原生库和本轮修改源码SHA-256见[validation.json](validation.json)。

## 支持边界与后续验收

日期卡片仍标为**部分支持**；正式清单42块，13已适配/28部分支持/1结构支持/0未适配，统计不变。

- 复杂桌面容器内的正式协同显示仍受所属容器支持范围限制；本轮不接管浮动定位、拖动缩放、对象动画、模板draft元数据编辑或旧固定框迁移。
- 原生布局保留12种样式的主要结构，但不承诺桌面CSS像素一致；票根镂空/虚线、细微字重/字距等装饰未完全复刻。
- 设置提供常用字体及预设字号/颜色。已保存的自定义值保留并尽量渲染；完整自定义数值/颜色输入、桌面字体文件和不同系统实际字体效果尚未覆盖。
- 未运行iOS完整构建、物理设备安装/操作、真实在线桌面双端或服务端持久化ACK验收。Android构建、宿主动态库测试和Yjs双副本收敛不代替这些验收。
