#!/bin/bash
# Produces build/Procul-<version>.zip, ready to hand to another Mac or to
# attach to a release. It will not produce a zip unless the tests pass and
# the privacy check finds nothing in the repo, its history or the zip.
set -euo pipefail
cd "$(dirname "$0")/.."

# A zip records file times as local time. UTC says nothing about where it was made.
export TZ=UTC

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/Procul-$VERSION.zip"
STAGE="build/package/Procul"

swift test 2>&1 | tail -1

# Ad hoc, so the download carries nobody's certificate.
CODESIGN_IDENTITY=- scripts/build.sh release

rm -rf build/package "$ZIP"
mkdir -p "$STAGE"
cp -R build/Procul.app "$STAGE/"
cp "packaging/Read Me First.txt" "$STAGE/"
ditto -c -k --norsrc --keepParent "$STAGE" "$ZIP"

if ! scripts/privacy-check.sh "$ZIP"; then
    rm -f "$ZIP"
    echo "package: no zip was produced." >&2
    exit 1
fi

echo "Packaged $ZIP"
shasum -a 256 "$ZIP"
