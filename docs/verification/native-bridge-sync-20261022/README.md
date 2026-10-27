# FRB 原生库版本不一致排查与恢复

日期：2026-10-22。范围：修复本地 iOS 与宿主测试原生构建产物过期，并为 IDE 完整 iOS 构建加入自动重建；未修改桥接接口、生成文件或文档数据。

## 原因与证据

- 用户错误：Dart 哈希 `1588999200`，已加载 Rust 哈希 `-1647568854`。
- 当前 `lib/src/native/frb_generated.dart` 与 `rust/src/frb_generated.rs` 均为 `1588999200`，两侧生成源码一致，无需重新生成。
- 本地 iOS XCFramework 时间为 2026-10-17；真机 arm64 的 `frb_get_rust_content_hash` 返回 `0x9dcc182a`，有符号值为 `-1647568854`，与报错完全一致。
- 重建前宿主测试 dylib 返回 `-2072767205`，也已过期。
- 修复前 iOS 使用 SwiftPM 本地二进制目标，直接从 IDE 启动 Flutter 不会执行仓库的原生库构建入口。热重载/热重启保留进程中已加载的旧库。

## 恢复与验证

- `example/scripts/build_rust_ios.sh debug`：真机 arm64、模拟器 arm64/x86_64 全部编译成功并更新 XCFramework。
- `cargo build --locked --manifest-path rust/Cargo.toml`：更新宿主测试 dylib。
- 重建后宿主 dylib 实际调用返回 `1588999200`；iOS 真机及模拟器 arm64 反汇编返回 `0x5eb63420`，即 `1588999200`。见 [content-hashes.txt](content-hashes.txt)。
- 包目录执行 `flutter test --no-pub test/collab_controller_native_test.dart test/collab_controller_lifecycle_native_test.dart --reporter expanded`：5 项通过，覆盖真实 FRB 初始化、单文档所有权、SQLite 恢复与初始化失败后的生命周期隔离。日志中预期的故障注入不代表测试失败。
- 宿主首次未配置动态库路径时 6 项失败，原因是默认加载器找不到 framework，并非哈希再次不一致。保留 `host-native-tests.log` 中的原始失败。
- 配置 `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$PWD/rust/target/debug"` 后重跑 `example/test/document_host_native_test.dart`：6 项全部通过，覆盖缓存打开、权限恢复及关闭/账号切换后的迟到结果隔离，见 `host-native-tests-with-library.log`。
- `flutter build ios --debug --no-pub`：签名真机应用构建成功。检查最终 `Runner.app/Frameworks/cses_collab_core.framework/cses_collab_core` 返回 `1588999200`，见 [packaged-ios-hash.txt](packaged-ios-hash.txt)。
- 停止旧 iOS Flutter 调试会话后，执行 `flutter run -d 00008101-001E59310E20001E --use-application-binary=build/ios/iphoneos/Runner.app --no-resident --no-pub`：安装启动完成，退出码 0。命令在文件同步后输出 `Lost connection to device`；因此没有将日志连接持续有效声明为通过。
- 随后用 `devicectl` 查询：`com.cses.csesMobileCollabDemo` 已安装在新应用目录，匹配的 `Runner` 进程 PID 3118 存活，见 [installed-app-process.json](installed-app-process.json)。未操作用户在线文档，实际重开原报错文档仍需用户侧确认。
- `git diff --check` 通过。本轮手写 Dart/Rust 源码未变更，因此未运行额外格式化或静态分析；已有工作区改动不纳入此次修改范围。

## 后续使用与边界

Rust/FRB 变化后，先停止调试，再从 IDE 或通过 `example/scripts/ios.sh run -d <ios-device-id>` 完整构建安装启动。测试库需要单独执行上述宿主 Cargo 构建。保留内容哈希校验，不跳过检查、不手工修改生成的哈希。

本轮不涉及 BlockCraft Schema 或块适配，不声明块兼容性重新验收。Android、iOS 模拟器应用启动及真实在线文档编辑未纳入本轮验收。工作区已有历史原型及公开入口改动保持原样，未替其声明验证通过。

## IDE 自动重建

- Runner 新增 `Build Rust iOS Library` 构建阶段，放在 Flutter 构建脚本之前、每次完整构建执行。所有通过该 Runner 工程的 IDE/Flutter 构建共用此入口，无需逐一配置 IDE。
- `example/scripts/build_rust_ios_xcode.sh` 按 `FLUTTER_BUILD_MODE`（优先）或 `CONFIGURATION` 选择 Debug/dev 与 Profile、Release/release。补充 Rustup/Homebrew PATH，调用既有三架构构建器，失败直接返回非零退出码。
- SwiftPM 可能已经处理旧的 XCFramework，因此成功后按真机/模拟器 slice 用 checksum 同步到 `BUILT_PRODUCTS_DIR/cses_collab_core.framework`，再由 Xcode 链接、嵌入与签名。保留 FRB 运行时哈希检查。
- 真机验证直接执行 `xcodebuild ... -configuration Debug -sdk iphoneos ... build`，未运行外层预构建脚本。先触碰手写 `rust/src/api/collab.rs` 的修改时间（内容不变），并向可丢弃的 SwiftPM 构建产物追加旧库标记。构建日志确认三架构自动编译、刷新产物，最终 `BUILD SUCCEEDED`；完成后 SwiftPM 二进制与重建的真机 XCFramework 二进制逐字节一致，旧库标记已消失。见 `ide-auto-rust-device-build.log`。
- 临时目录中的 8 项脚本契约检查全部通过：Debug/Profile/Release、带后缀配置、Flutter mode 优先级、错误平台/配置、原生构建失败传播（42）、同尺寸同 mtime 的旧库替换、旧 framework 文件清除。详见 [ide-hook-contract-checks.json](ide-hook-contract-checks.json)。
- 直接 `xcodebuild ... -configuration Debug -sdk iphonesimulator ... CODE_SIGNING_ALLOWED=NO build` 完整构建通过，日志确认自动构建和模拟器 slice 刷新，见 `ide-auto-rust-simulator-build.log`。真机/模拟器 SwiftPM 产物均与对应重建 slice 逐字节一致，最终应用内嵌库的 arm64 内容哈希均为 `1588999200`，见 [ide-auto-rust-products.json](ide-auto-rust-products.json)。
- `bash -n`、Xcode 工程 `plutil -lint` 与 `git diff --check` 通过。此次仅新增脚本、构建配置和文档，未改动 Dart/Rust 源码内容，未重复运行上一阶段的桥接测试。
- Release/Profile 仅验证配置映射，未重新完成整包归档或设备启动；VS Code/Android Studio 按钮未分别点击验收。本阶段验证构建与产物，未重新安装或启动模拟器/手机应用。
- 全新检出缺少 XCFramework 时，SwiftPM 解析发生在此阶段之前，仍先执行已有初始化入口。热重载/热重启不触发 Xcode 完整构建，修改 Rust 后须停止并重新启动调试。

构建阶段失败语义参考 [Apple 自定义构建脚本文档](https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build)。
