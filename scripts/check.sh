#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# CLT lacks XCTest/Testing; this executable runs real assertions without downloading dependencies.
swift run --package-path "$PROJECT_ROOT/packages/RadarCore" RadarCoreChecks
python3 "$PROJECT_ROOT/scripts/validate-fixtures.py"
