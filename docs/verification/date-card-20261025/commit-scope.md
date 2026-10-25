# 日期适配提交核查（2026-10-25）

提交包含正式date-card协同投影/字段历史、12种原生样式及设置、插入/删除/锁、JSON往返、审查三项修复，以及底部弹窗中的居中吸顶预览、左右循环样式按钮和下方名称；同步支持范围、技能规则和历轮证据。

工作区同时存在天气适配、宿主天气服务、内容分类文档及根版本号修改。本次从HEAD构造日期独立快照，逐处拆分共用文件，仅暂存日期范围；工作区内容保留，未提交天气及其他改动。实现与验证指纹见[JSON记录](commit-validation.json)。

## 版本核对

在桌面项目配置的包仓库重新执行npm view：latest仍为0.11.30；桌面声明/Yarn锁为0.11.28，实际安装0.11.21，未升级。日期相关随包技能、MIGRATIONS及实现的三版核对沿用本日[指纹记录](sticky-version.json)，当前提交未引入新的桌面契约变化。

## 独立快照验证

- 本次19个手写Dart文件执行格式化，按既有行宽；19目标Flutter静态分析无问题，见[日志](commit-analyze-targets.log)。
- Rust格式检查、cargo check、cargo build通过；crate全部197项测试通过，见[测试日志](commit-rust-tests.log)。vendor既有警告保留。
- 日期模型/组件、三项缺陷与面板回归、公共弹窗、JSON和原生链路共47项通过，见[日志](commit-flutter-tests.log)。
- 日期快捷插入专项1项通过，见[日志](commit-toolbar-tests.log)。
- 用独立日期源码重新构建dylib，再执行真实FRB/原生历史/SQLite重开2项通过，见[日志](commit-native-tests.log)。
- 暂存范围检查确认无天气功能新增；git diff --cached --check与工作区git diff --check通过。

扩展静态检查编辑器目录时发现未修改的collab_video_block.dart:265既有unawaited_futures提示，见[完整日志](commit-analyze.log)；定向19目标检查无问题。既有工具栏禁用能力基线失败保留在[初轮报告](report.md)，本轮仅重跑日期直接插入专项，未声明该旧用例通过。

本轮未新增完整平台App构建、物理设备或真实在线双端验证；复杂容器、自由定位/缩放/动画等限制继续见适配表。47项中含原生测试，额外2项用于确认重新构建的独立日期库，不作为新的独立用例累加。
