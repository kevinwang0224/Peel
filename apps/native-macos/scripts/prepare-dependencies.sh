#!/bin/bash
set -euo pipefail
native_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$native_root/Dependencies"
fetch() {
  local name="$1" archive="$2" checksum="$3"
  if [[ -f "$native_root/Dependencies/$name/.peel-version" ]] && [[ "$(cat "$native_root/Dependencies/$name/.peel-version")" == "$checksum" ]]; then return; fi
  local staging
  staging="$(mktemp -d)"
  curl --fail --location --retry 2 "https://www.scintilla.org/$archive" -o "$staging/$archive"
  if [[ "$(shasum -a 256 "$staging/$archive" | cut -d ' ' -f 1)" != "$checksum" ]]; then
    rm -rf "$staging"
    echo "Checksum mismatch for $archive" >&2; exit 1
  fi
  tar -xzf "$staging/$archive" -C "$staging"
  rm -rf "$native_root/Dependencies/$name"
  mv "$staging/$name" "$native_root/Dependencies/$name"
  printf '%s\n' "$checksum" > "$native_root/Dependencies/$name/.peel-version"
  rm -rf "$staging"
}
fetch scintilla scintilla567.tgz 19e4476706750056f86ca70974810e4a5b08e73477e13f7d9fae78243606f6a7
fetch lexilla lexilla554.tgz fcd9ef74236a12359d1039827c93dbf827aa476c46f9fd6eef60bb96db1af2f6
