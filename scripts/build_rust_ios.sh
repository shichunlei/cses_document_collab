#!/usr/bin/env bash
# Compatibility entry for existing CI commands; implementation travels with the package.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
exec "$ROOT/packages/cses_document_collab/tool/build_rust_ios.sh" "$@"
