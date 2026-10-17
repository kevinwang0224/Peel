#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
vendor_root="$project_root/Sources/PeelEditor/Vendor"
mkdir -p "$vendor_root"
fetch() {
  local name="$1" archive="$2" checksum="$3"
  if [[ -f "$vendor_root/$name/.peel-version" ]] && [[ "$(cat "$vendor_root/$name/.peel-version")" == "$checksum" ]]; then return; fi
  local staging
  staging="$(mktemp -d)"
  curl --fail --location --retry 2 "https://www.scintilla.org/$archive" -o "$staging/$archive"
  if [[ "$(shasum -a 256 "$staging/$archive" | cut -d ' ' -f 1)" != "$checksum" ]]; then
    rm -rf "$staging"
    echo "Checksum mismatch for $archive" >&2; exit 1
  fi
  tar -xzf "$staging/$archive" -C "$staging"
  rm -rf "$vendor_root/$name"
  mv "$staging/$name" "$vendor_root/$name"
  printf '%s\n' "$checksum" > "$vendor_root/$name/.peel-version"
  rm -rf "$staging"
}
fetch scintilla scintilla567.tgz 19e4476706750056f86ca70974810e4a5b08e73477e13f7d9fae78243606f6a7
fetch lexilla lexilla554.tgz fcd9ef74236a12359d1039827c93dbf827aa476c46f9fd6eef60bb96db1af2f6

# 5.6.7 reads chars[-1] when laying out an empty line. Keep the local fix
# reproducible after downloading dependencies, and reject unexpected source drift.
layout_patch="$project_root/patches/scintilla-empty-line-layout.patch"
if patch --dry-run --silent --forward -p1 -d "$vendor_root/scintilla" < "$layout_patch" >/dev/null 2>&1; then
  patch --silent --forward -p1 -d "$vendor_root/scintilla" < "$layout_patch"
elif ! patch --dry-run --silent --reverse -p1 -d "$vendor_root/scintilla" < "$layout_patch" >/dev/null 2>&1; then
  echo "Scintilla empty-line patch does not match the dependency source." >&2
  exit 1
fi

# With scroll width tracking the document view shrinks to the text width, leaving the rest of the
# editor unclickable. Keep it at least as wide as the viewport.
width_patch="$project_root/patches/scintilla-document-min-width.patch"
if patch --dry-run --silent --forward -p1 -d "$vendor_root/scintilla" < "$width_patch" >/dev/null 2>&1; then
  patch --silent --forward -p1 -d "$vendor_root/scintilla" < "$width_patch"
elif ! patch --dry-run --silent --reverse -p1 -d "$vendor_root/scintilla" < "$width_patch" >/dev/null 2>&1; then
  echo "Scintilla document-width patch does not match the dependency source." >&2
  exit 1
fi
