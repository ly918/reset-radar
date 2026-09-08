#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/scripts/build-demo.sh"
open "$PROJECT_ROOT/build/Reset Radar.app"
