# 天气刷新入口移入操作面板

日期：2026-10-26，同轮卡片操作调整的后续要求。

“刷新天气”仅在点击整卡后打开的公共操作面板中提供，使用refreshCw图标；卡片下方移除刷新/重试按钮。天气内容继续持有本地加载状态与请求代次，通过可选actionBuilder将异步刷新能力借给块操作入口，不转移编辑器或宿主查询资源所有权。

未配置天气服务、当前加载中、锁定或只读时不提供刷新操作。失败仍在卡片原状态区提示，可重新打开菜单刷新；固定日成功刷新仍为单次可撤销frozen修改，实时天气不落盘。菜单会话、重复操作、源属性/身份/服务变化和撤权后的迟到请求保护保持。

验证命令（包目录）：

```sh
dart format --line-length 120 lib/src/editor/collab_weather_block.dart lib/src/editor/collab_weather_content.dart lib/src/editor/collab_block_actions.dart test/collab_weather_test.dart
flutter analyze --no-pub lib/src/editor/collab_weather_block.dart lib/src/editor/collab_weather_content.dart lib/src/editor/collab_block_actions.dart test/collab_weather_test.dart test/collab_card_tap_actions_test.dart
flutter test --no-pub test/collab_weather_test.dart test/collab_card_tap_actions_test.dart test/collab_block_actions_test.dart --reporter expanded
git diff --check
```

目标回归包含正式卡片点击菜单、刷新图标、刷新成功/撤销、失败保留旧值及菜单重试成功、撤权恢复拒绝迟到结果、实时不落盘，以及锁定/只读/无服务菜单不提供刷新。最终83项通过，5文件静态分析无问题，格式化与diff检查通过。结果见[最终测试日志](weather-refresh-tests.log)及[静态检查](weather-refresh-analyze.log)。

保留测试修正过程：[首轮](weather-refresh-tests-initial.log)79通过/1失败，原测试精确匹配状态文字而实际经典样式会组合城市和状态；改为包含匹配后80项通过。增加权限三场景后[第二轮](weather-refresh-tests-readonly-fixture.log)82通过/1失败，原测试宿主AppFlowyEditor默认editable=true覆盖状态；宿主显式传入当前editable后重新验证。以上均为测试定位/宿主修正，不修改产品权限判断来绕过失败。

本轮重新在桌面配置仓库查询latest，ECONNRESET，保持待核对；声明/Yarn0.11.30、安装0.11.17，未升级。重新读取安装包与本地声明版产物随包技能/迁移及天气刷新实现，文档指纹保持，详见[版本证据](blockcraft-version.json)的weatherRefreshFollowup。未新增原生构建、Android/iOS真机或真实在线双端验收，42块及13/28/1/0统计不变。
