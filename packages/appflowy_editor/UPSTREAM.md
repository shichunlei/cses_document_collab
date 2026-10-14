# AppFlowy Editor 本地源码基线

- 上游项目：https://github.com/AppFlowy-IO/appflowy-editor
- 上游发布版本：`appflowy_editor 6.2.0`
- 发布归档：https://pub.dev/api/archives/appflowy_editor-6.2.0.tar.gz
- 归档 SHA-256：`c2367acdd93c7eeefaf6c58e5fed1a1c62cf02b8368102b786b5c6a0d1c583cf`
- 导入方式：完整解压 pub.dev 发布归档；未引入嵌套 Git 仓库。

本目录保留上游发布包的源码、资源、示例、测试和 `LICENSE`。后续兼容性修改应在此目录维护，并以该发布版本为比较基线。

## 本地依赖约束

- 此本地包要求 Flutter `>=3.44.0`、Dart `>=3.12.0 <4.0.0`，不发布到 pub.dev。
- `file_picker 13.1.0` 与 `device_info_plus 13.3.0` 对齐 `cses.saas` 的已解析版本；其余直接依赖采用 Dart 3.12 可解析的版本。
- 依赖按 Flutter `3.44.9` / Dart `3.12.2` 升级至可解析的最高稳定版本，包含开发与示例依赖。运行依赖使用 `html 0.15.7`，开发依赖使用 `intl_utils 2.8.17`、`mockito 5.7.0` 和 `path_provider 2.1.6`。
- Flutter 的 `flutter_localizations` 固定 `intl 0.20.2`，`flutter_test` 固定 `meta 1.18.0`。Mockito 更高版本依赖的 analyzer 要求更高的 meta，因此在 Flutter 3.44 下保留 `mockito 5.7.0`，不覆盖 SDK 约束。
- 示例使用 `google_fonts 8.2.1`、`printing 5.15.1`、`show_fps 1.1.0` 和 `flutter_lints 6.0.0`；`google_fonts 9` 要求 Flutter 3.47 / Dart 3.13，不能用于此基线。示例已有的 Git 插件引用继续保留。
- 文本差异算法直接依赖 pub.dev `diff_match_patch ^0.4.1`；菜单滚动直接依赖 pub.dev `scroll_to_index ^3.0.1`，不再维护这两个包的本地 fork。
- 节点 ID 使用 `nanoid2` 生成六字符 URL 安全标识，键盘高度监听使用 `keyboard_height_plugin 0.3.0`。
- 示例工程沿用 AppFlowy 的 pub.dev `diff_match_patch` 依赖，不设置本地路径 override。
- 文件选择接口使用 `file_picker 13.1.0` 的静态 API；返回的文件通过 `readAsBytes()` 读取，保存操作传入字节并返回 URI。
- 示例 macOS 工程要求最低 macOS 10.15，并保留 Flutter 3.44 生成的 Swift Package Manager 工程配置。示例独有的同步插件目前仍通过 CocoaPods 集成。
- 示例 iOS 工程要求最低 iOS 14，与 `cses.jqdl` 的部署目标及 `file_picker_darwin` 的平台要求一致；保留 Flutter 3.44 的 UIScene 与 Swift Package Manager 工程配置。
- 示例 Android 工程采用 Flutter 的声明式 Gradle 插件配置，AGP `8.13.2`、Kotlin `2.3.20`、Gradle `8.14.5` 和 Java 17，与 `cses.jqdl` 的构建工具链对齐。
- 示例 Android 关闭 Jetifier，避免对 Flutter 引擎 JAR 做额外转换；当前示例依赖在此配置下可以完成构建。同步插件仍作为示例专属依赖存在。
