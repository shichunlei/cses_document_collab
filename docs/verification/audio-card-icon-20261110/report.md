# 音频卡片与底部弹窗图标统一

2026-11-10，音频卡片标题栏改用底部操作弹窗的紫色波形图标（`LucideIcons.audioLines`）。两处共用 `CollabTypeIcon`，沿用弹窗图标的尺寸、圆角和亮暗配色。

- 对三个涉及的 Dart 文件运行了 `dart format`，保留本次改动范围内的格式化结果。
- Flutter 对三个文件的静态分析无诊断。
- `collab_resource_block_test.dart` 和 `collab_block_actions_test.dart` 共 79 项通过，覆盖音频卡片布局、播放控件及块菜单标题等现有行为。
- `git diff --check` 通过。本轮未进行真机视觉验收。
