# cses_collab_core native builder

Requires Flutter 3.44.0 or later and Dart 3.10 or later. Android uses Cargokit. The iOS host uses
Swift Package Manager; the plugin also retains CocoaPods compatibility.

## Swift Package Manager

The manifest is `ios/cses_collab_core/Package.swift`. Its binary target consumes a
local dynamic `cses_collab_core.xcframework`, containing device arm64 and simulator
arm64/x86_64 slices. The framework exports the Flutter Rust Bridge entry points.

From the app root, use `scripts/ios.sh build ios --debug --no-codesign` or
`scripts/ios.sh run -d <ios-device-id>`. The wrapper builds Rust before Flutter
resolves packages. For Xcode builds, run `scripts/build_rust_ios.sh debug` first;
use `release` before archiving. Run it again after Rust changes. Generated binaries
are ignored by Git and must be generated after a clean checkout.

## CocoaPods

`ios/cses_collab_core.podspec` continues to build the Rust static library through
Cargokit for other hosts that use CocoaPods. Its framework stub lives in the single
`ios/cses_collab_core/Sources/cses_collab_core` source tree; there is no separate
`Classes` directory. SPM consumes the Rust binary target directly.
This app uses only SPM and does not provide a CocoaPods fallback configuration.
