#!/usr/bin/env bash
set -euo pipefail
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_root="${FLUTTER_ROOT:-$(dirname "$(dirname "${FLUTTER_BIN:-${HOME}/flutter/bin/flutter}")")}"
framework_dir="${flutter_root}/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/maclauncher-window-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

# Compile the production window/delegate with a native test entry point.
# Removing only @main leaves all lifecycle implementations unchanged.
sed '/^@main$/d' "$workspace_root/launcher/macos/Runner/AppDelegate.swift" > "$test_dir/AppDelegate.swift"
cp "$workspace_root/launcher/macos/Tests/ManagementWindowClose.swift" "$test_dir/main.swift"
xcrun swiftc \
  -F "$framework_dir" -framework FlutterMacOS \
  -Xlinker -rpath -Xlinker "$framework_dir" \
  -module-cache-path "$test_dir/cache" \
  "$test_dir/AppDelegate.swift" \
  "$workspace_root/launcher/macos/Runner/MainFlutterWindow.swift" \
  "$workspace_root/launcher/macos/Flutter/GeneratedPluginRegistrant.swift" \
  "$test_dir/main.swift" \
  -o "$test_dir/window-test"
"$test_dir/window-test"
