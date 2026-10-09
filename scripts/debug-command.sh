#!/bin/bash
# Sends one command to a running debug build of Procul.
#   scripts/debug-command.sh toggle
#   scripts/debug-command.sh snapshot:/tmp/panel.png
# The commands are listed in Sources/Procul/App.swift.
set -euo pipefail
/usr/bin/osascript -l JavaScript - "$1" <<'JS'
function run(argv) {
    ObjC.import("Foundation");
    $.NSDistributedNotificationCenter.defaultCenter
        .postNotificationNameObjectUserInfoDeliverImmediately(
            "io.github.hypomaniac.Procul.debug", argv[0], $(), true);
}
JS
