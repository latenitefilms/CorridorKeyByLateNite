#!/bin/bash
set -euo pipefail
test_directory="$(cd "$(dirname "$0")" && pwd)"
source_directory="$(cd "$test_directory/../.." && pwd)"
plugin_directory="$source_directory/CorridorKeyByLateNite/Plugin"
build_directory="$(mktemp -d /tmp/corridorkey-fxplug-tests.XXXXXX)"
trap 'rm -rf "$build_directory"' EXIT
framework_directory=/Library/Developer/Frameworks
sdk_framework_directory=/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks

xcrun clang -fobjc-arc -Wno-protocol -c "$test_directory/FxPlugTestHost.m" \
    -I "$plugin_directory/Shared" -F "$sdk_framework_directory" \
    -o "$build_directory/host.o"
xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 \
    -module-cache-path "$build_directory/module-cache" \
    -import-objc-header "$test_directory/FxPlugTestHost.h" -I "$plugin_directory/Shared" \
    -F "$sdk_framework_directory" -F "$framework_directory" \
    "$framework_directory/FxPlug.framework/FxPlug" -framework CoreMedia -framework Metal -framework PluginManager \
    -Xlinker -rpath -Xlinker "$framework_directory" \
    "$test_directory/ManualHintHostTests.swift" "$test_directory/UnusedRenderDependencies.swift" \
    "$plugin_directory/Inspector/CorridorKeyHintOSC.swift" \
    "$plugin_directory/Inspector/CustomParameterValue.swift" \
    "$plugin_directory/Inspector/HeaderCustomParameterStorage.swift" \
    "$plugin_directory/Inspector/OnScreenControlTool.swift" \
    "$plugin_directory/Inspector/HintHitTesting.swift" \
    "$plugin_directory/Inspector/HintPointSet.swift" \
    "$plugin_directory/Parameters/ParameterIdentifiers.swift" \
    "$plugin_directory/Parameters/ParameterEnumerations.swift" \
    "$plugin_directory/Inference/DeviceCapabilityCache.swift" \
    "$build_directory/host.o" -o "$build_directory/ManualHintHostTests"
"$build_directory/ManualHintHostTests"
