#!/bin/bash
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
renderer_bundle="${1:?Pass the path to an unsigned Debug renderer .pluginkit bundle}"
renderer_executable="$renderer_bundle/Contents/MacOS/CorridorKey by LateNite Renderer"
build_directory="$(mktemp -d /tmp/corridorkey-model-loading-tests.XXXXXX)"
trap 'rm -rf "$build_directory"' EXIT
framework_directory=/Library/Developer/Frameworks
sdk_framework_directory=/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks

xcrun clang -fobjc-arc -dynamiclib -arch arm64 -mmacosx-version-min=15.6 \
    -F "$sdk_framework_directory" -F "$framework_directory" \
    "$framework_directory/FxPlug.framework/FxPlug" -framework Foundation -framework PluginManager \
    -Xlinker -rpath -Xlinker "$framework_directory" \
    "$test_directory/ModelLoadingHostTests.m" -o "$build_directory/ModelLoadingHostTests.dylib"

# Inject only into this newly launched renderer. The replacement principal
# exercises real startup and instance creation without opening Final Cut Pro.
LLVM_PROFILE_FILE="$build_directory/idle-renderer.profraw" \
    DYLD_INSERT_LIBRARIES="$build_directory/ModelLoadingHostTests.dylib" "$renderer_executable"
