#!/usr/bin/env bash
set -euo pipefail
workspace_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$workspace_root"
flutter_command="${FLUTTER_BIN:-${HOME}/flutter/bin/flutter}"
dart_command="${DART_BIN:-${HOME}/flutter/bin/dart}"

check_format() {
  "$dart_command" format --output=none --set-exit-if-changed packages example launcher/lib launcher/test
}

check_analysis() {
  "$flutter_command" --suppress-analytics analyze --no-pub
}

check_tests() {
  "$dart_command" test packages/launcher_core/test
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
