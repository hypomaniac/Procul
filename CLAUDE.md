# Procul

A macOS menu bar remote for Apple TV. Swift app plus a Python helper built on pyatv. README.md has the layout, the helper protocol and the user-facing behaviour. DECISIONS.md has what was settled and why.

## Rules

- The app never speaks an Apple TV protocol itself. Anything that talks to the TV goes in `helper/atv_helper.py` through pyatv, and reaches the app as a JSON event.
- The helper protocol is listed in README.md. Update the list when a command or event changes.
- The shipped app must not depend on Python being installed. `scripts/build.sh` freezes the helper with PyInstaller. Keep versions pinned in `helper/requirements.txt`.
- No third-party Swift packages.
- Record a new material decision in DECISIONS.md under the next D-number. Do not reopen a settled one unless asked.

## Privacy

This repo is published under a pseudonym. Nothing in it may identify the owner, the household, their machines or their network.

- Write docs, comments, commit messages and decisions without names of people, computers, towns or employers. Say "a second Mac in the house".
- Commits use the repo-local identity already set in `.git/config`. Do not override it.
- Commit with `TZ=UTC git commit`. A commit records its time zone, and the privacy check refuses any that is not UTC.
- Make release zips with `scripts/package.sh` only. It signs ad hoc, strips the source paths out of the binary and will not leave a zip behind if the privacy check fails.
- Run `scripts/privacy-check.sh` before every commit that will be pushed, and pass the zip to it before every release. It reads `.private-strings`, which is gitignored and must stay that way.
- Release builds are signed ad hoc (`CODESIGN_IDENTITY=-`). A local certificate is for local installs only.
- Never push, publish a release or change repo visibility without being told to in that conversation.

## Checking work

- `swift test` covers the model's handling of helper events against a scripted fake helper.
- `swift build` then `.build/debug/Procul --snapshot <dir>` renders every screen to PNG. Look at them after any view change.
- `scripts/install.sh debug` installs a build that answers `scripts/debug-command.sh`. Use `state:<path>` to read the live state and `snapshot:<path>` to photograph the real panel.
- The helper can be driven by hand: pipe JSON lines into `.venv/bin/python helper/atv_helper.py <credentials-file>`.
- App status changes go to the unified log: `/usr/bin/log show --last 2m --info --predicate 'subsystem == "io.github.hypomaniac.Procul"'`.
- Pairing needs a person in front of the TV to read the code. Nothing can click the panel's buttons from a script, so anything that depends on a real click or key press needs a person too.
- Finish with `scripts/install.sh` so the installed app is the release build.

## Style

- Short declarative sentences in anything the user reads. No em dashes.
- American spelling in the interface, to match Apple's own labels.
