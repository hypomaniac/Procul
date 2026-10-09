#!/bin/bash
# Builds the app, puts it in /Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh "${1:-release}"

osascript -e 'quit app id "io.github.hypomaniac.Procul"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Procul.app
cp -R build/Procul.app /Applications/
open /Applications/Procul.app
echo "Installed. Look for the remote icon in the menu bar."
