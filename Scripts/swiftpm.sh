#!/bin/bash
set -euo pipefail

case "${1:-}" in
    build|test|run) ACTION="$1"; shift ;;
    *) echo "Usage: $0 {build|test|run} [options]" >&2; exit 2 ;;
esac

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

# AppKit uses the linked SDK version to choose behaviour such as sheet resizing.
# Keep the deployment target aligned with Package.swift; applying it to dependencies
# too keeps their link steps from receiving conflicting minimum versions.
exec swift "$ACTION" \
    --triple "$(uname -m)-apple-macosx15.0" \
    -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$SDK_VERSION" \
    "$@"
