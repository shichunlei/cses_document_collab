#!/usr/bin/env bash
# Runner build phase: rebuild Rust and refresh SwiftPM's processed framework
# before linking/embedding. Xcode may have copied the previous XCFramework
# while planning the build, so rebuilding the package artifact alone is not enough.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

# GUI-launched Xcode does not inherit the interactive shell's Rustup PATH.
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
case "${FLUTTER_BUILD_MODE:-${CONFIGURATION:-}}" in
  debug|Debug|Debug-*) PROFILE=debug;;
  release|profile|Release|Release-*|Profile|Profile-*) PROFILE=release;;
  *) echo "error: Unsupported Rust iOS build configuration: ${CONFIGURATION:-unset}" >&2; exit 2;;
esac
case "${PLATFORM_NAME:-}" in
  iphoneos) SLICE=ios-arm64;;
  iphonesimulator) SLICE=ios-arm64_x86_64-simulator;;
  *) echo "error: Unsupported Rust iOS platform: ${PLATFORM_NAME:-unset}" >&2; exit 2;;
esac
: "${BUILT_PRODUCTS_DIR:?Xcode must provide BUILT_PRODUCTS_DIR}"

echo "Building Rust iOS library ($PROFILE, $PLATFORM_NAME)"
"$ROOT/scripts/build_rust_ios.sh" "$PROFILE"
FRAMEWORK=cses_collab_core.framework
SOURCE="$ROOT/packages/cses_document_collab/ios/cses_document_collab/cses_collab_core.xcframework/$SLICE/$FRAMEWORK"
DESTINATION="$BUILT_PRODUCTS_DIR/$FRAMEWORK"
if [[ ! -d "$SOURCE" || ! -d "$DESTINATION" ]]; then
  echo "error: Missing Rust framework source or SwiftPM build product: $SOURCE -> $DESTINATION" >&2
  exit 1
fi
# --checksum also replaces a stale binary whose size and mtime happen to match.
# The source is unsigned; Xcode signs the final embedded copy with the app.
/usr/bin/rsync -a --checksum --delete "$SOURCE/" "$DESTINATION/"
echo "Updated Rust SwiftPM build product: $DESTINATION"
