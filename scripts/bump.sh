#!/usr/bin/env bash
# Bump the VERSION file. Landing the bump on main is what triggers a release.
set -euo pipefail

cd "$(dirname "$0")/.."
IFS=. read -r major minor patch < VERSION

case "${1:-}" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "usage: $0 major|minor|patch" >&2; exit 1 ;;
esac

printf '%s.%s.%s\n' "$major" "$minor" "$patch" > VERSION
echo "VERSION -> $(cat VERSION)"
