# Decisions

What was settled, in the order it was settled. Each entry is final unless a later one replaces it by number.

**Status:** phases 1 (identity) and 2 (features) are built. Phase 3 (packaging, update checker, the public repo, the first release, the second Mac) has not started and waits for a go-ahead.

## Shape

- **D1. A Swift menu bar app drives a Python helper.** The helper wraps pyatv and speaks JSON lines over stdin and stdout. The app never implements an Apple TV protocol itself. Pairing needs SRP and the Companion protocol, and pyatv already has both.
- **D2. The helper is frozen into the app with PyInstaller.** An earlier remote stopped working after a system update. The shipped app must not depend on whatever Python the Mac has.
- **D3. No third-party Swift packages.**
- **D4. One Apple TV.** A picker exists for a house with more, but it stays basic.

## The remote

- **D5. Clicks and keys only.** The ring moves one step per click and repeats when held. No swipe surface: gestures over the network lag, and the arrow keys cover fast movement.
- **D6. Volume stays.** It works through the TV on the setup this was built for.
- **D7. Power: click turns on, hold turns off.** A stray click must not sleep the TV in the middle of a show.
- **D8. Holding the TV button opens Control Center.** The Companion protocol has no "hold Home" command.
- **D9. Keys always go over Companion.** Once Now Playing is paired, pyatv would route key presses over that link by default. The helper asks for Companion by name so that behaviour does not change after the second pairing.

## The panel

- **D10. A popover with a pin.** Unpinned, it hangs under the menu bar and closes when you click away. Pinned, it floats above other windows and remembers where it was dragged.
- **D11. The panel never activates the app.** It is a non-activating panel that takes the keyboard while the app you were using stays in front. That is what lets a shortcut hand the keyboard over and back.
- **D12. A global shortcut, Control-Option-R by default, changeable from the menu.** Unpinned, it shows and hides the remote. Pinned, it gives the remote the keyboard, and a second press gives it back.
- **D13. Esc is Back on the TV.** It never closes the panel. The shortcut or a click elsewhere does that.

## Now Playing

- **D14. Setup is two codes in a row.** The second pairs AirPlay, which carries what is playing. It can be skipped.
- **D15. A Mac with only the first pairing gets one prompt.** "Finish Setup" or "Later". Later is remembered per TV.
- **D16. Title, show or artist, and a Play/Pause button that shows what a press will do.** No artwork and no scrub bar.
- **D17. If connecting with Now Playing fails, the helper connects with the remote alone.** A broken second pairing must not take the remote down with it.

## Apps

- **D18. Up to six favorites in one row,** chosen from a checklist, kept in the order they were ticked. Each Mac has its own list.
- **D19. Icons come from Apple's public App Store lookup,** fetched once per favorite and cached. Apps with no listing get a lettered tile. This is the only thing the app asks the internet for.

## Text

- **D20. A text field appears when the TV wants text.**
- **D21. A notification for it is a per-Mac switch, off by default.** With the app on several Macs, nobody gets notifications they did not ask for. The panel never opens by itself, because it would steal keystrokes from whatever was being typed.

## Other switches

- **D22. Open at Login is a switch, off by default.**

## Identity and publishing

- **D23. The app is called Procul.** It is described as "a menu bar remote for Apple TV". It does not use Apple's product name as its own, and its icon is drawn from scratch.
- **D24. Published under a pseudonym, with nothing that identifies the owner, the household, their machines or their network.** Commits use a repo-local identity. The bundle identifier carries the pseudonym.
- **D25. A privacy check gates publishing.** It scans tracked files, commit history and release zips for a private list of strings. The list is never committed. A missing list is a failure, not a pass.
- **D26. Releases are signed ad hoc.** A developer certificate would publish its owner's email in every download. The cost is that macOS may ask again for Local Network access after an update.
- **D27. MIT licence. Issues off. No support promised.**
- **D28. The repo is created private.** The owner reads it as a stranger would and makes it public by hand. Every push and every release waits for an explicit go-ahead.

## Distribution

- **D29. Other Macs in the house get a zip,** copied over by hand, with a one-time "Open Anyway". Apple silicon, macOS 14 or later. No notarization.
- **D30. An update checker reports, it does not install.** It asks the public releases list at launch and once a day and offers to open the release page. With an ad hoc signature there is nothing to verify a download against. It is a switch, on by default.

## Process

- **D31. Tests cover the model's handling of helper events,** against a scripted fake helper. They run locally. No CI, which would also mean build logs to keep clean.
- **D32. Layout is checked from rendered snapshots,** and a debug build can be driven and photographed from a script. Anything that needs a real click or a code read off the TV needs a person.
