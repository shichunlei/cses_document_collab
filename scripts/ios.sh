#!/usr/bin/env bash
# Examples: scripts/ios.sh build ios --debug --no-codesign
#           scripts/ios.sh run -d <ios-device-id>
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
PROFILE=debug
for ARG in "$@"; do
  case "$ARG" in
    --release|--profile) PROFILE=release;;
  esac
done
# Flutter's build ios/ipa defaults to release, while flutter run defaults to debug.
if [[ "${1:-}" == build ]]; then
  PROFILE=release
  for ARG in "$@"; do
    [[ "$ARG" != --debug ]] || PROFILE=debug
  done
fi
"$ROOT/scripts/build_rust_ios.sh" "$PROFILE"
cd "$ROOT"
exec flutter "$@"
