#!/usr/bin/env bash
# Release helper for the drift_sync monorepo.
#
# Usage: ./scripts/release.sh <package> <version>
#
# Bumps the version in <package>/pubspec.yaml, opens its CHANGELOG.md
# for editing, commits the change, and tags it as `<package>-v<version>`.
# Does not publish — run `cd packages/<package> && dart pub publish`
# afterward.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <package> <version>"
  echo "Example: $0 drift_sync_core 0.3.0"
  exit 1
fi

PACKAGE="$1"
VERSION="$2"
PKG_DIR="packages/$PACKAGE"

if [[ ! -d "$PKG_DIR" ]]; then
  echo "Error: $PKG_DIR does not exist"
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree has uncommitted changes; commit or stash first"
  exit 1
fi

# Bump version
sed -i.bak "s/^version: .*/version: $VERSION/" "$PKG_DIR/pubspec.yaml"
rm "$PKG_DIR/pubspec.yaml.bak"
echo "Bumped $PACKAGE to $VERSION"

# Open CHANGELOG for the user to add an entry
echo "Opening $PKG_DIR/CHANGELOG.md — add an entry for $VERSION."
"${EDITOR:-vi}" "$PKG_DIR/CHANGELOG.md"

git add "$PKG_DIR/pubspec.yaml" "$PKG_DIR/CHANGELOG.md"
git commit -m "chore($PACKAGE): Release v$VERSION"
git tag "$PACKAGE-v$VERSION"

echo
echo "✓ Committed and tagged as $PACKAGE-v$VERSION"
echo "  Next: cd $PKG_DIR && dart pub publish"
echo "  Then: git push --follow-tags"
