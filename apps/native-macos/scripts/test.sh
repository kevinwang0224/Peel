#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$native_root/scripts/prepare-dependencies.sh"
swift build --package-path "$native_root" --product PeelScript
bin_dir="$(swift build --package-path "$native_root" --show-bin-path)"
PEEL_SCRIPT_PATH="$bin_dir/PeelScript" swift test --package-path "$native_root" "$@"
