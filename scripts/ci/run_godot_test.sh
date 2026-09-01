#!/usr/bin/env bash
set -euo pipefail

godot_bin="${1:-godot}"
suite="${2:-res://tests/run_m0_tests.gd}"
log_dir="${3:-/tmp/dynasty-rebellion-godot-test}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mkdir -p "$log_dir"
engine_log="$log_dir/godot.log"
run_log="$log_dir/test-output.log"
scan_log="$log_dir/error-scan.log"

set +e
"$godot_bin" --headless --path "$project_root" --log-file "$engine_log" -s "$suite" >"$run_log" 2>&1
exit_code=$?
set -e

sed -n '1,240p' "$run_log"

# Godot 4.6.1 on macOS can emit this exact two-line certificate lookup error
# after a successful headless run. It does not originate from project code.
sed \
  -e '/^ERROR: Condition "ret != noErr" is true\. Returning: ""$/d' \
  -e '/get_system_ca_certificates (platform\/macos\/os_macos\.mm:/d' \
  "$run_log" >"$scan_log"

marker_pattern='SCRIPT ERROR|Parse Error|Invalid call|TEST FAIL:|ERROR:'
if rg -n "$marker_pattern" "$scan_log"; then
  echo "Godot error marker scan failed." >&2
  exit 1
fi

if [[ $exit_code -ne 0 ]]; then
  echo "Godot suite exited with code $exit_code." >&2
  exit "$exit_code"
fi

if ! rg -q 'TEST SUMMARY: [0-9]+ passed, 0 failed' "$run_log"; then
  echo "Godot suite did not report an explicit zero-failure summary." >&2
  exit 1
fi
