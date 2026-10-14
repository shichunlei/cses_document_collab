#!/usr/bin/env bash
# Prepare the local SwiftPM binary before Flutter/Xcode resolves packages.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PROFILE=${1:-debug}
case "$PROFILE" in
  debug) CARGO_FLAGS=(--profile dev);;
  release|profile) PROFILE=release; CARGO_FLAGS=(--release);;
  *) echo "Usage: $0 [debug|release|profile]" >&2; exit 2;;
esac
LIB=cses_collab_core
TARGET_DIR="$ROOT/build/rust-ios"
STAGING="$TARGET_DIR/frameworks-$PROFILE"
PACKAGE_DIR="$ROOT/ios/cses_document_collab"
mkdir -p "$STAGING"
# Cargo uses the appropriate SDK for each Rust target. An SDKROOT inherited
# from Xcode must not force simulator compilation to use the device SDK.
unset SDKROOT
export IPHONEOS_DEPLOYMENT_TARGET=14.0
for TARGET in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  cargo build --locked --manifest-path "$ROOT/rust/Cargo.toml" \
    --target-dir "$TARGET_DIR" --target "$TARGET" "${CARGO_FLAGS[@]}"
done
for PLATFORM in iphoneos iphonesimulator; do
  FRAMEWORK="$STAGING/$PLATFORM/$LIB.framework"
  mkdir -p "$FRAMEWORK/Headers" "$FRAMEWORK/Modules"
  if [[ "$PLATFORM" == iphoneos ]]; then
    cp "$TARGET_DIR/aarch64-apple-ios/$PROFILE/lib$LIB.dylib" "$FRAMEWORK/$LIB"
    SUPPORTED_PLATFORM=iPhoneOS
  else
    lipo -create "$TARGET_DIR/aarch64-apple-ios-sim/$PROFILE/lib$LIB.dylib" \
      "$TARGET_DIR/x86_64-apple-ios/$PROFILE/lib$LIB.dylib" -output "$FRAMEWORK/$LIB"
    SUPPORTED_PLATFORM=iPhoneSimulator
  fi
  install_name_tool -id "@rpath/$LIB.framework/$LIB" "$FRAMEWORK/$LIB"
  cat > "$FRAMEWORK/Headers/$LIB.h" <<'HEADER'
#ifndef CSES_COLLAB_CORE_H
#define CSES_COLLAB_CORE_H
#include <stdint.h>
// Flutter Rust Bridge checks this value when initializing the native library.
int32_t frb_get_rust_content_hash(void);
#endif
HEADER
  cat > "$FRAMEWORK/Modules/module.modulemap" <<MODULE
framework module $LIB {
  umbrella header "$LIB.h"
  export *
}
MODULE
  cat > "$FRAMEWORK/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.cses.collab.core</string>
<key>CFBundleExecutable</key><string>$LIB</string>
<key>CFBundleName</key><string>$LIB</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>14.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>$SUPPORTED_PLATFORM</string></array>
</dict></plist>
PLIST
done
# Generate away from the package, so a failed build leaves the last artifact intact.
XCFRAMEWORK="$STAGING/$LIB.xcframework"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
  -framework "$STAGING/iphoneos/$LIB.framework" \
  -framework "$STAGING/iphonesimulator/$LIB.framework" \
  -output "$XCFRAMEWORK"
rm -rf "$PACKAGE_DIR/$LIB.xcframework"
mv "$XCFRAMEWORK" "$PACKAGE_DIR/$LIB.xcframework"
