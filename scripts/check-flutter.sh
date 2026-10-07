#!/usr/bin/env bash
set -euo pipefail
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$workspace_root"
flutter_command="${FLUTTER_BIN:-$(command -v flutter || echo "${HOME}/flutter/bin/flutter")}"
dart_command="${DART_BIN:-$(command -v dart || echo "${HOME}/flutter/bin/dart")}"

check_format() {
  # 检查模式（--output=none）不改文件；失败时给出修复命令，避免把
  # 「Formatted N files」误读成「已格式化」。
  if ! "$dart_command" format --output=none --set-exit-if-changed packages example launcher/lib launcher/test; then
    echo "格式检查未过（以上文件未格式化）。修复：dart format packages example launcher/lib launcher/test" >&2
    return 1
  fi
}

check_analysis() {
  "$flutter_command" --suppress-analytics analyze --no-pub
}

check_tests() {
  "$dart_command" test packages/maclauncher_sdk/test packages/launcher_core/test
  (cd launcher && "$flutter_command" --suppress-analytics test --no-pub)
}

case "${1:-check}" in
  format) check_format ;;
  analyze) check_analysis ;;
  test) check_tests ;;
  check)
    check_format
    check_analysis
    check_tests
    ;;
  *)
    echo 'Usage: scripts/check-flutter.sh [check|format|analyze|test]' >&2
    exit 2
    ;;
esac
