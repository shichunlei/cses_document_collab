# Android SDK XML 版本警告核查

日期：2026-10-29。

## 核查与修改

- 用户报告 `SDK processing ... only understands SDK XML versions up to 3 ... version 4`。
- 同样警告存在于历史 `../mermaid-20261017/mermaid-android-20261017.txt` 和 `../offline-journal-20261023/cover-android-build.txt`。历史证据未修改。
- 当前命令行工具 `cmdline-tools/latest/source.properties` 为 23.0；`sdkmanager --version` 转交 Android CLI 并返回 `1.0.15985488 (Android CLI)`。
- 宿主已使用 AGP 8.13.2、Gradle 8.14.5、compileSdk/targetSdk 36；核心插件仍声明 AGP 8.11.1，与其“和宿主保持一致”的注释不符。本次将核心插件声明对齐为 8.13.2。
- `example/README.md` 补充实际 SDK/JDK 路径检查、命令行工具更新和构建入口说明。
- [官方兼容表](https://developer.android.com/build/releases/agp-8-13-0-release-notes)确认 AGP 8.13 要求 Gradle 至少 8.13、JDK 至少 17；本次不切换 AGP 9，也不修改 SDK 元数据或依赖缓存。

## 验证依据与限制

- 初次直接运行 `./gradlew :app:assembleDebug --console=plain` 使用 PATH 中的 Android Studio Java 25.0.2，配置阶段以 `25.0.2` 失败，见 [直接 Gradle 日志](direct-gradle-java25.log)。
- `flutter doctor -v` 确认 Flutter 3.44.9 已配置 Temurin Java 17.0.20.1。使用该 JDK 复跑上述命令，见 [修改前 Java 17 构建日志](baseline-java17.log)。该次配置阶段仍使用原 AGP 8.11.1，未复现用户报告的 XML 警告；因此不能声称已用前后对照证明本次版本对齐消除了该警告。
- 修改前 Java 17 基线构建通过：`BUILD SUCCESSFUL in 1m 12s`，581 个任务，其中 32 个执行。
- 修改后在 `example/` 执行 `flutter build apk --debug` 通过，Gradle 耗时 66.0 秒，生成 `example/build/app/outputs/flutter-apk/app-debug.apk`；见 [构建日志](flutter-build-debug.log)。日志中未出现 `SDK processing` 或 `SDK XML` 警告。构建包含 Rust Android 原生库。
- `git diff --check` 通过。本次未修改 Dart、Rust 源码，不适用 Dart format/analyze 或 Rust 源码检查要求。
- `flutter doctor -v` 另报告 Android license status unknown；未代替用户接受许可。设备交互、release 签名与其他宿主未验收。
