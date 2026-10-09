# Procul

A menu bar remote for Apple TV, for macOS 14 and later on Apple silicon.

*Procul* is Latin for "at a distance". Say it "PRO-kool".

This is a personal project. It is published as is, with no support.

## What it does

Click the remote icon in the menu bar, or press Control-Option-R from any app.

- A clickpad, Back, TV, Play/Pause, volume, 10-second skip and a power button.
- Arrow keys, Return, Esc and Space drive the TV while the remote has the keyboard.
- A pin button turns the popover into a small window that floats above everything else and remembers where you put it.
- Up to six favorite apps as one-click buttons, and a menu of every app on the TV.
- A line showing what is playing, with a Play/Pause button that shows what a press will do.
- When the Apple TV wants text, a text field appears and what you type shows up on the TV. A notification for this can be turned on per Mac.

## Install

From a release: unzip, move Procul to Applications and open it. macOS will refuse the first time, because the app is not notarized. Go to System Settings, Privacy & Security, scroll to the message about Procul and choose Open Anyway. That is needed once.

From source:

```bash
scripts/install.sh
```

This builds the app, copies it to `/Applications` and starts it. Building needs Xcode's command line tools and Python 3. The finished app carries its own copy of everything and needs no Python.

## First run

1. macOS asks to let Procul find devices on the local network. Allow it.
2. Open the remote and choose **Pair**. The Apple TV shows a code. Type it in.
3. The Apple TV shows a second code. That one adds the Now Playing line. You can skip it and do it later from the menu.

## Using it

| Control | Mouse | Keyboard |
| --- | --- | --- |
| Move | Click the ring. Hold to repeat. | Arrow keys |
| Select | Click the center. Hold for a long press. | Return. Shift-Return for a long press. |
| Back | Back button. Hold for Home. | Esc or Delete |
| TV / Home | TV button. Hold for Control Center. | H. Shift-H for Control Center. |
| Play or pause | Play/Pause button | Space |
| Volume | Rocker. Hold to repeat. | + and - |
| Skip 10 seconds | Skip buttons | [ and ] |
| Power | Click to turn on. Hold to turn off. | |
| Show or hide | Menu bar icon | Control-Option-R |
| Quit | Menu under the TV name | Cmd-Q |

The global shortcut shows and hides the remote. When the remote is pinned, the shortcut hands it the keyboard, and a second press gives the keyboard back to the app you were in. Change the shortcut from the menu under the TV name.

While the text field has focus, typing goes to the Apple TV. Press Return or Esc to give the keys back to the remote.

Volume goes through the Apple TV, so it works when the TV or receiver takes volume over HDMI-CEC or when the Apple TV drives HomePods.

## What it talks to

- Your Apple TV, over the local network.
- Apple's public App Store lookup, once per favorite app, to fetch its icon. Apps with no listing get a lettered tile.

Nothing else. Pairing credentials stay in `~/Library/Application Support/Procul/credentials.json`, readable only by you.

## How it works

```
Swift menu bar app  <- JSON lines over stdin/stdout ->  helper/atv_helper.py (pyatv)  <- Companion protocol ->  Apple TV
```

- `Sources/Procul` is the app. `RemoteModel` holds the state. `PanelController` owns the menu bar item, the panel and the keyboard. `RemoteView` draws the remote. `HelperProcess` runs the helper.
- `helper/atv_helper.py` wraps [pyatv](https://pyatv.dev). It takes one JSON command per line and writes one JSON event per line. `scripts/build.sh` freezes it with PyInstaller into the app bundle.
- The helper logs to `~/Library/Logs/Procul/helper.log`.

### Helper protocol

Commands: `scan`, `connect {id}`, `disconnect`, `pair_begin {id, protocol}`, `pair_pin {pin}`, `pair_cancel`, `key {key, action}`, `power {on}`, `text {text}`, `apps`, `launch {id}`, `forget {id}`.

Events: `ready`, `devices`, `needs_pairing`, `pin_requested`, `paired`, `pair_failed`, `connected`, `disconnected`, `power`, `keyboard`, `playing`, `apps`, `forgotten`, `error`.

## Development

```bash
swift build
swift test
.build/debug/Procul --snapshot build/snapshots
```

The last command renders every screen of the remote to PNG files in light and dark, with no Apple TV needed.

```bash
scripts/install.sh debug
scripts/debug-command.sh toggle
scripts/debug-command.sh snapshot:/tmp/panel.png
```

A debug build answers commands sent this way, which is how the panel can be driven and photographed from a script.

Before anything is published:

```bash
scripts/privacy-check.sh
```

It scans tracked files, commit history and optionally a release zip for the strings listed in `.private-strings`, a file that is never committed.

## If it stops working

- **Nothing found.** Check System Settings, Privacy & Security, Local Network and make sure Procul is on.
- **Pairing refused.** On the Apple TV, look at Settings, AirPlay and HomeKit, Allow Access. "Anyone on the Same Network" works.
- **Broke after a tvOS update.** Raise the `pyatv` version in `helper/requirements.txt` and run `scripts/install.sh` again. The protocol work all lives in pyatv.
- **Start over.** Choose Forget This Apple TV from the menu, then pair again.

## Credits

Built on [pyatv](https://pyatv.dev), which does all the protocol work. Apple TV is a trademark of Apple Inc. This project is not affiliated with Apple.

MIT licence. See `LICENSE`.
