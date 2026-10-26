# 人员、天气、日期卡片整卡操作

日期：2026-10-26。

## 实施范围

- 三类正式块移除额外的 `CollabCardFrame`、12像素外侧内容留白和右上角更多按钮独占行，直接显示卡片本体。卡片自己的样式边框设置保留，块间上下6像素间距及锁标保留。
- 整卡点击复用 `CollabBlockMoreButton.triggerBuilder` 打开公共底部操作弹窗，继续提供各自设置、删除、下方插入以及按宿主配置可用的锁和段落链接；沿用菜单防重入、权限代次、稳定身份、快照及失败处理。
- 公共触发器在纯内容预览中保留自定义本体并传入空回调，避免整卡触发面改造后预览内容消失。没有只读操作的只读卡片保持显示且无法打开修改菜单。
- 不改共享属性、设置草稿、历史事务、天气查询、Rust桥接或宿主接口。

## 验证

包目录：`packages/cses_document_collab`。

```sh
dart format --line-length 120 lib/src/editor/collab_person_card_block.dart lib/src/editor/collab_weather_block.dart lib/src/editor/collab_date_card_block.dart lib/src/editor/collab_block_actions.dart test/collab_card_tap_actions_test.dart
flutter analyze --no-pub lib/src/editor/collab_person_card_block.dart lib/src/editor/collab_weather_block.dart lib/src/editor/collab_date_card_block.dart lib/src/editor/collab_block_actions.dart test/collab_card_tap_actions_test.dart
flutter test --no-pub test/collab_card_tap_actions_test.dart test/collab_block_actions_test.dart test/collab_person_card_test.dart test/collab_date_card_test.dart test/collab_weather_test.dart test/collab_page_divider_test.dart test/collab_block_lock_test.dart --reporter expanded
git diff --check
```

最终128项通过，5文件静态分析无问题，最终格式检查0变化，diff检查通过。详见[测试日志](flutter-tests.log)、[分析日志](flutter-analyze.log)。新增12项覆盖三类卡片320像素视口下的整卡打开设置/取消、删除/撤销、无额外外框/更多按钮、只读与纯内容预览、重复点击、撤权再恢复后的旧菜单拒绝。既有回归覆盖公共菜单、锁、字段历史与设置权限。

首轮102项中94通过、8失败，失败均为新增测试使用精确无障碍朗读文本定位天气/日期卡片：子内容合并后不再等于外层标签。改为按Semantics自身标签定位后，新增12项独立通过，最终关联128项全通过。未改产品行为来规避该定位失败。

受限环境内Flutter启动无法写SDK缓存、直接Dart启动CPU探测失败；授权执行后格式化、分析、测试正常完成。未新增Android/iOS真机、完整平台构建、截图或真实在线桌面双向验收。本次UI入口验证不代表三类块全部桌面能力已适配。

## BlockCraft版本核对

桌面配置 `@ccc:registry=http://npm.runtongqiuben.com/`；在桌面项目运行 `npm view @ccc/blockcraft@latest version dist --json`，初次ENOTFOUND，授权联网重试ECONNRESET。**上游latest待核对**，不以历史0.11.30宣称当前最新。

本轮实际声明/Yarn锁定0.11.30，安装包package.json为0.11.17，历史pnpm仍0.2.78；未修改桌面依赖。读取安装包与本地已有0.11.30发布产物的随包L0、块技能、MIGRATIONS及三类Schema/渲染实现。三类Schema指纹一致；安装包日期实现含独立设置路由生命周期，与0.11.30产物不同，不能按安装包标注版本推断全部实现相同。本次只改移动展示和操作入口，不据此声明版本全量兼容。

[版本及指纹证据](blockcraft-version.json)。本地0.11.30是已存在的声明版本产物，本轮未能联网核对最新dist，未将其当成本次下载或最新包。自由布局/缩放/动画、模板物化、完整剪贴板、天气旧缺失frozen的无Undo初始化，以及设备/在线验收沿用各块清单待办。42块与13已适配/28部分支持/1结构支持/0未适配保持，三类卡片均为部分支持。

后续要求：[天气刷新移入操作面板](weather-refresh.md)，该轮验证独立记录，保留上文原128项结论。

后续修复：[锁标跟随卡片实际展示边界](card-lock-layout.md)，保留前述各轮原始验证结论。

提交前核对（2026-10-26）：仅纳入本轮三类卡片整卡操作、天气刷新菜单、锁标本体定位、关联测试与同主题证据；排除已有appflowy_editor/file_picker依赖改动与日成果JSON。既有128/83/79项分轮回归及分析日志均已核对，计数含重叠；未无故重复运行。桌面声明/Yarn0.11.30、安装0.11.17及随包文档/三类Schema指纹保持，联网重查latest仍ECONNRESET，状态继续待核对；未升级桌面依赖。

归档日志仅移除行尾空格以满足diff检查，保留所有测试内容、失败与最终通过结论。
