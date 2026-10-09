#!/bin/bash
# Builds build/Procul.app: the Swift app plus a frozen copy of the pyatv
# helper, so the finished app needs no Python on the machine.
#
#   scripts/build.sh           release build
#   scripts/build.sh debug     debug build, which also answers debug commands
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Procul.app"

if [ ! -x .venv/bin/python ]; then
    python3 -m venv .venv
fi
.venv/bin/python -m pip install --quiet -r helper/requirements.txt

.venv/bin/python -m PyInstaller --noconfirm --log-level WARN --onedir --name atv_helper \
    --distpath build/helper --workpath build/pyinstaller --specpath build/pyinstaller \
    helper/atv_helper.py

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helper"
cp ".build/$CONFIG/Procul" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R build/helper/atv_helper "$APP/Contents/Resources/helper/"

# CODESIGN_IDENTITY picks the signature. "-" is ad hoc, which is what a
# build meant for other people gets. With nothing set, a local Apple
# Development certificate is used if there is one, because a stable
# signature lets macOS remember the Local Network permission across builds.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
find "$APP/Contents/Resources/helper" -type f \( -name '*.so' -o -name '*.dylib' -o -perm +111 \) -print0 |
    xargs -0 codesign --force --sign "$CODESIGN_IDENTITY" 2>/dev/null
codesign --force --sign "$CODESIGN_IDENTITY" "$APP" 2>/dev/null
codesign --verify --strict "$APP"

if [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "Built $APP ($CONFIG, ad hoc signature)"
else
    echo "Built $APP ($CONFIG, signed with a local certificate)"
fi
