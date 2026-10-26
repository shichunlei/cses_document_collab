# 卡片锁标跟随实际展示边界

日期：2026-10-26。同轮卡片操作的后续修复，依据用户提供的天气与日期截图。

## 原因和改动

去额外外框后，整卡点击面仍按整行宽度铺开；锁覆盖层也在该点击面外侧，导致窄卡片右侧留白时锁标定位到行尾。日期/天气的作者宽高与实际设计比例还可能不同，FittedBox内部留白也不能作为可见卡片边界。

- 人员、天气、日期块移除点击面外侧的锁覆盖层；点击面积与整块选区保持。
- 三类原生展示组件在缩放后的实际表面外使用共用CollabCardLockOverlay；天气/日期先用applyBoxFit计算实际等比绘制尺寸，并遵循有限宽高约束，再放置锁层。作者宽高、预览对齐和共享属性不改写。
- 小锁保持14逻辑像素，位置为实际卡片top/right各向外5像素，处于FittedBox与圆角/内容裁切之外；锁图标不随卡片尺寸放大缩小。
- 沿用显式普通锁标记作用域，解锁后隐藏；锁菜单、设置、删除、天气刷新及只读/预览行为保持。

## 验证

在packages/cses_document_collab目录执行：

```sh
dart format --line-length 120 lib/src/editor/collab_person_card_block.dart lib/src/editor/collab_weather_block.dart lib/src/editor/collab_date_card_block.dart lib/src/ui/modal/collab_person_card_visual.dart lib/src/ui/modal/collab_weather_visual.dart lib/src/ui/modal/collab_date_card_visual.dart test/collab_card_tap_actions_test.dart
flutter analyze --no-pub lib/src/editor/collab_person_card_block.dart lib/src/editor/collab_weather_block.dart lib/src/editor/collab_date_card_block.dart lib/src/ui/modal/collab_person_card_visual.dart lib/src/ui/modal/collab_weather_visual.dart lib/src/ui/modal/collab_date_card_visual.dart test/collab_card_tap_actions_test.dart
flutter test --no-pub test/collab_card_tap_actions_test.dart test/collab_person_card_test.dart test/collab_weather_test.dart test/collab_date_card_test.dart test/person_card_bottom_sheet_test.dart test/weather_bottom_sheet_test.dart test/date_card_regression_test.dart --reporter expanded
git diff --check
```

最终79项通过，七文件分析无问题，格式化和diff检查通过；[测试日志](card-lock-layout-tests.log)、[分析日志](card-lock-layout-analyze.log)。新增六项正式编辑器回归覆盖三类卡片，作者宽度180/600、固定高度280，在320像素手机视口验证窄卡片及宽卡片缩放、日期/天气比例留白、锁标相对实际表面的top/right精确位置与固定14像素、祖先裁切可见性、整卡打开锁操作、解锁隐藏，以及正文快照/撤销栈不变。原12项整卡操作与三类设置预览、窄屏、草稿和天气刷新回归继续通过。

未新增Android/iOS真机、截图或真实在线桌面双向验收，不把几何回归等同于物理设备验收。

## 版本与待办

本次通过桌面配置仓库重新查询latest，仍ECONNRESET，最新稳定版待核对；声明/Yarn0.11.30、实际安装标注0.11.17，未升级。复读安装版与本地声明版产物的L0、块技能、迁移及三类Schema/受影响展示实现，文档指纹与本轮记录一致。上游等比绘制契约保持，本轮仅修复移动标记边界。详见[版本证据](blockcraft-version.json)的cardLockLayoutFollowup。

三类块保持部分支持，42及13/28/1/0不变；自由布局、完整剪贴板、天气旧缺失frozen初始化及设备/在线待办继续保留。
