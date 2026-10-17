#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$project_root/scripts/prepare-dependencies.sh"
swift build --package-path "$project_root" --product PeelScript
bin_dir="$(swift build --package-path "$project_root" --show-bin-path)"
PEEL_SCRIPT_PATH="$bin_dir/PeelScript" swift test --package-path "$project_root" "$@"
