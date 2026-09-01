#!/usr/bin/env bash
set -euo pipefail

log_root="${1:-/tmp/dynasty-rebellion-tests}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

"$project_root/scripts/ci/run_godot_test.sh" godot res://tests/run_m0_tests.gd "$log_root/m0"
"$project_root/scripts/ci/run_godot_test.sh" godot res://tests/run_m1_combat_tests.gd "$log_root/m1"
