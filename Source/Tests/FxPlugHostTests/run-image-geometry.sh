#!/bin/bash
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
source_directory="$(cd "$test_directory/../.." && pwd)"
plugin_directory="$source_directory/CorridorKeyByLateNite/Plugin"
build_directory="$(mktemp -d /tmp/corridorkey-image-geometry.XXXXXX)"
trap 'rm -rf "$build_directory"' EXIT
framework_directory=/Library/Developer/Frameworks
sdk_framework_directory=/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks

xcrun swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos15.6 \
    -module-cache-path "$build_directory/module-cache" \
    -import-objc-header "$plugin_directory/Shared/CorridorKeyByLateNite-Bridging-Header.h" \
    -F "$sdk_framework_directory" -F "$framework_directory" \
    "$framework_directory/FxPlug.framework/FxPlug" -framework CoreMedia -framework PluginManager \
    -Xlinker -rpath -Xlinker "$framework_directory" \
    "$test_directory/ImageGeometryHostTests.swift" \
    "$plugin_directory/CorridorKeyByLateNitePlugIn+RenderRects.swift" \
    -o "$build_directory/ImageGeometryHostTests"
"$build_directory/ImageGeometryHostTests"
