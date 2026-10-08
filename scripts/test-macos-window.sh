#!/usr/bin/env bash
set -euo pipefail
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_root="${FLUTTER_ROOT:-$(dirname "$(dirname "${FLUTTER_BIN:-${HOME}/flutter/bin/flutter}")")}"
framework_dir="${flutter_root}/bin/cache/artifacts/engine/darwin-x64/FlutterMacOS.xcframework/macos-arm64_x86_64"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/maclauncher-window-test.XXXXXX")"
test_dir="$(cd "$test_dir" && pwd -P)"
trap 'rm -rf "$test_dir"' EXIT
test_app="$test_dir/WindowTest.app"
mkdir -p "$test_app/Contents/MacOS"

# Preserve the production agent-app declaration while using a test entry point.
python3 - "$workspace_root/launcher/macos/Runner/Info.plist" "$test_app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    agent = plistlib.load(source).get('LSUIElement', False)
with open(sys.argv[2], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'dev.ghost233.maclauncher.window-test',
        'CFBundleExecutable': 'window-test',
        'CFBundleName': 'WindowTest',
        'CFBundlePackageType': 'APPL',
        'LSUIElement': agent,
    }, output)
PY

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
  -o "$test_app/Contents/MacOS/window-test"
codesign --force --sign - "$test_app"
"$test_app/Contents/MacOS/window-test"
