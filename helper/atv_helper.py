#!/usr/bin/env python3
"""Bridge between the Procul app and pyatv.

Reads one JSON command per line on stdin and writes one JSON event per line
on stdout. Logging goes to stderr. The protocol is documented in README.md.

Usage: atv_helper.py <credentials-file>
"""

import asyncio
import json
import logging
import os
import sys

import pyatv
from pyatv import exceptions
from pyatv.const import (
    DeviceState,
    InputAction,
    KeyboardFocusState,
    OperatingSystem,
    PairingRequirement,
    PowerState,
    Protocol,
)
from pyatv.interface import (
    DeviceListener,
    KeyboardListener,
    PowerListener,
    PushListener,
)
from pyatv.storage.file_storage import FileStorage

_LOGGER = logging.getLogger("atv_helper")

SCAN_TIMEOUT = 4
PAIRING_NAME = "Procul"

# Keys that accept a tap, double tap or hold.
ACTION_KEYS = {"up", "down", "left", "right", "select", "menu", "home"}

# Keys that are a plain press.
SIMPLE_KEYS = {
    "play_pause",
    "play",
    "pause",
    "stop",
    "next",
    "previous",
    "skip_forward",
    "skip_backward",
    "volume_up",
    "volume_down",
    "home_hold",
    "top_menu",
    "screensaver",
    "control_center",
    "guide",
    "channel_up",
    "channel_down",
}

ACTIONS = {
    "single": InputAction.SingleTap,
    "double": InputAction.DoubleTap,
    "hold": InputAction.Hold,
}

PROTOCOLS = {"companion": Protocol.Companion, "airplay": Protocol.AirPlay}


def emit(event, **fields):
    """Write one event to the app."""
    fields["event"] = event
    sys.stdout.write(json.dumps(fields) + "\n")
    sys.stdout.flush()


def has_credentials(conf, protocol):
    service = conf.get_service(protocol)
    return service is not None and bool(service.credentials)


def describe(conf):
    info = conf.device_info
    return {
        "id": conf.identifier,
        "name": conf.name,
        "address": str(conf.address),
        "model": info.model_str,
        "os": f"tvOS {info.version}" if info.version else "tvOS",
        "paired": has_credentials(conf, Protocol.Companion),
        "nowPlayingPaired": has_credentials(conf, Protocol.AirPlay),
    }


class Helper(DeviceListener, PowerListener, KeyboardListener, PushListener):
    def __init__(self, loop, storage):
        self.loop = loop
        self.storage = storage
        self.atv = None
        self.device_id = None
        self.pairing = None
        self.pairing_protocol = None

    # Commands

    async def handle(self, msg):
        cmd = msg.get("cmd")
        handler = getattr(self, f"cmd_{cmd}", None)
        if handler is None:
            emit("error", cmd=cmd, message=f"Unknown command {cmd}")
            return
        try:
            await handler(msg)
        except exceptions.NotSupportedError:
            emit("error", cmd=cmd, message="The Apple TV does not support that right now.")
        except (exceptions.ConnectionLostError, exceptions.BlockedStateError, OSError) as ex:
            _LOGGER.warning("Connection problem during %s: %s", cmd, ex)
            await self.disconnect()
            emit("disconnected", reason=str(ex) or type(ex).__name__)
        except Exception as ex:  # pylint: disable=broad-except
            _LOGGER.exception("Command %s failed", cmd)
            emit("error", cmd=cmd, message=str(ex) or type(ex).__name__)

    async def cmd_scan(self, _msg):
        confs = await pyatv.scan(self.loop, timeout=SCAN_TIMEOUT, storage=self.storage)
        devices = [
            describe(conf)
            for conf in confs
            if conf.device_info.operating_system == OperatingSystem.TvOS
            and conf.get_service(Protocol.Companion) is not None
        ]
        devices.sort(key=lambda device: device["name"])
        emit("devices", devices=devices)

    async def cmd_connect(self, msg):
        await self.connect(msg["id"])

    async def cmd_disconnect(self, _msg):
        await self.disconnect()
        emit("disconnected", reason="")

    async def cmd_pair_begin(self, msg):
        await self.close_pairing()
        protocol = PROTOCOLS[msg.get("protocol", "companion")]
        conf = await self.find(msg["id"])
        if conf is None:
            emit("error", cmd="pair_begin", message="Could not find that Apple TV on the network.")
            return
        # A live connection can hold the pairing screen off, so let go of it.
        await self.disconnect()
        self.pairing = await pyatv.pair(
            conf, protocol, self.loop, storage=self.storage, name=PAIRING_NAME
        )
        self.pairing_protocol = msg.get("protocol", "companion")
        await self.pairing.begin()
        emit("pin_requested", id=conf.identifier, protocol=self.pairing_protocol)

    async def cmd_pair_pin(self, msg):
        if self.pairing is None:
            emit("error", cmd="pair_pin", message="Pairing has not been started.")
            return
        protocol = self.pairing_protocol
        try:
            self.pairing.pin(str(msg["pin"]).strip())
            await self.pairing.finish()
            paired = self.pairing.has_paired
        except exceptions.PairingError as ex:
            _LOGGER.warning("Pairing failed: %s", ex)
            paired = False
        finally:
            await self.close_pairing()
        if paired:
            await self.storage.save()
            emit("paired", protocol=protocol)
        else:
            emit("pair_failed", protocol=protocol, message="That code did not work. Try again.")

    async def cmd_pair_cancel(self, _msg):
        await self.close_pairing()

    async def cmd_key(self, msg):
        key = msg["key"]
        atv = await self.ensure_connected()
        if atv is None:
            return
        # Once Now Playing is paired pyatv would route keys over that link
        # instead. Companion is the one a remote is meant to use.
        remote = atv.remote_control.get(Protocol.Companion) or atv.remote_control
        if key in ACTION_KEYS:
            await getattr(remote, key)(ACTIONS[msg.get("action", "single")])
        elif key in SIMPLE_KEYS:
            await getattr(remote, key)()
        else:
            emit("error", cmd="key", message=f"Unknown key {key}")

    async def cmd_power(self, msg):
        atv = await self.ensure_connected()
        if atv is None:
            return
        turn_on = msg.get("on")
        if turn_on is None:
            turn_on = atv.power.power_state != PowerState.On
        if turn_on:
            await atv.power.turn_on()
        else:
            await atv.power.turn_off()

    async def cmd_text(self, msg):
        atv = await self.ensure_connected()
        if atv is None:
            return
        text = msg.get("text", "")
        if text:
            await atv.keyboard.text_set(text)
        else:
            await atv.keyboard.text_clear()

    async def cmd_apps(self, _msg):
        atv = await self.ensure_connected()
        if atv is None:
            return
        apps = await atv.apps.app_list()
        listing = [{"id": app.identifier, "name": app.name} for app in apps]
        listing.sort(key=lambda app: (app["name"] or "").lower())
        emit("apps", apps=listing)

    async def cmd_launch(self, msg):
        atv = await self.ensure_connected()
        if atv is None:
            return
        await atv.apps.launch_app(msg["id"])

    async def cmd_forget(self, msg):
        """Drop stored credentials for a device."""
        conf = await self.find(msg["id"])
        await self.disconnect()
        if conf is not None:
            await self.storage.remove_settings(await self.storage.get_settings(conf))
            await self.storage.save()
        emit("forgotten", id=msg["id"])

    # Connection

    async def find(self, identifier):
        confs = await pyatv.scan(
            self.loop, identifier=identifier, timeout=SCAN_TIMEOUT, storage=self.storage
        )
        return confs[0] if confs else None

    async def connect(self, identifier):
        await self.disconnect()
        self.device_id = identifier
        conf = await self.find(identifier)
        if conf is None:
            emit("disconnected", reason="Could not find the Apple TV on the network.")
            return None
        if not has_credentials(conf, Protocol.Companion):
            emit("needs_pairing", **describe(conf))
            return None

        # An unpaired protocol only gets in the way, so leave it out.
        for service in conf.services:
            if service.pairing == PairingRequirement.Mandatory and not service.credentials:
                service.enabled = False
        # AirPlay streaming is not used. Only the Now Playing channel is.
        raop = conf.get_service(Protocol.RAOP)
        if raop is not None:
            raop.enabled = False

        try:
            atv = await self.open(conf)
        except exceptions.AuthenticationError:
            emit("needs_pairing", **describe(conf))
            return None
        self.atv = atv
        atv.listener = self
        atv.power.listener = self
        atv.keyboard.listener = self
        now_playing = False
        try:
            atv.push_updater.listener = self
            atv.push_updater.start()
            now_playing = True
        except exceptions.NotSupportedError:
            pass

        emit(
            "connected",
            power=self.power_name(atv.power.power_state),
            keyboardFocused=self.keyboard_focused(),
            **describe(conf),
        )
        if self.keyboard_focused():
            await self.send_keyboard_state()
        if now_playing:
            # Push updates only report changes. Ask once for where things stand.
            try:
                self.playstatus_update(None, await atv.metadata.playing())
            except Exception:  # pylint: disable=broad-except
                _LOGGER.debug("Reading Now Playing failed", exc_info=True)
        return atv

    async def open(self, conf):
        """Connect, falling back to the remote alone if Now Playing is the problem."""
        airplay = conf.get_service(Protocol.AirPlay)
        try:
            return await pyatv.connect(conf, self.loop, storage=self.storage)
        except exceptions.AuthenticationError:
            raise
        except Exception:  # pylint: disable=broad-except
            if airplay is None or not airplay.enabled:
                raise
            _LOGGER.exception("Connecting with Now Playing failed. Trying the remote alone.")
            airplay.enabled = False
            return await pyatv.connect(conf, self.loop, storage=self.storage)

    async def ensure_connected(self):
        if self.atv is not None:
            return self.atv
        if self.device_id is None:
            emit("error", cmd="connect", message="No Apple TV selected.")
            return None
        return await self.connect(self.device_id)

    async def disconnect(self):
        atv, self.atv = self.atv, None
        if atv is not None:
            atv.listener = None
            await asyncio.gather(*atv.close(), return_exceptions=True)

    async def close_pairing(self):
        pairing, self.pairing = self.pairing, None
        self.pairing_protocol = None
        if pairing is not None:
            try:
                await pairing.close()
            except Exception:  # pylint: disable=broad-except
                _LOGGER.debug("Closing pairing failed", exc_info=True)

    # State

    @staticmethod
    def power_name(state):
        return {PowerState.On: "on", PowerState.Off: "off"}.get(state, "unknown")

    def keyboard_focused(self):
        try:
            return self.atv.keyboard.text_focus_state == KeyboardFocusState.Focused
        except Exception:  # pylint: disable=broad-except
            return False

    async def send_keyboard_state(self):
        focused = self.keyboard_focused()
        text = ""
        if focused:
            try:
                text = await self.atv.keyboard.text_get() or ""
            except Exception:  # pylint: disable=broad-except
                _LOGGER.debug("Reading keyboard text failed", exc_info=True)
        emit("keyboard", focused=focused, text=text)

    # Listeners

    def connection_lost(self, exception):
        _LOGGER.warning("Connection lost: %s", exception)
        self.atv = None
        emit("disconnected", reason=str(exception) or "Connection lost")

    def connection_closed(self):
        if self.atv is not None:
            self.atv = None
            emit("disconnected", reason="")

    def powerstate_update(self, old_state, new_state):
        emit("power", state=self.power_name(new_state))

    def focusstate_update(self, old_state, new_state):
        if self.atv is not None:
            self.loop.create_task(self.send_keyboard_state())

    def playstatus_update(self, updater, playstatus):
        state = {
            DeviceState.Playing: "playing",
            DeviceState.Paused: "paused",
            DeviceState.Loading: "loading",
        }.get(playstatus.device_state, "idle")
        app = None
        try:
            app = self.atv.metadata.app.name
        except Exception:  # pylint: disable=broad-except
            pass
        emit(
            "playing",
            state=state,
            title=playstatus.title,
            artist=playstatus.artist,
            album=playstatus.album,
            app=app,
            position=playstatus.position,
            total=playstatus.total_time,
        )

    def playstatus_error(self, updater, exception):
        _LOGGER.debug("Now Playing update failed: %s", exception)


async def read_commands(loop):
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    while True:
        line = await reader.readline()
        if not line:
            return
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            emit("error", cmd=None, message="Malformed command")


async def main():
    if len(sys.argv) != 2:
        sys.exit("usage: atv_helper.py <credentials-file>")
    path = sys.argv[1]
    os.makedirs(os.path.dirname(path), exist_ok=True)

    logging.basicConfig(
        level=logging.DEBUG if os.environ.get("ATV_DEBUG") else logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    loop = asyncio.get_running_loop()
    storage = FileStorage(path, loop)
    await storage.load()
    # The file holds pairing credentials. Keep it private.
    if not os.path.exists(path):
        await storage.save()
    os.chmod(path, 0o600)

    helper = Helper(loop, storage)
    emit("ready", version=pyatv.const.__version__)
    try:
        async for msg in read_commands(loop):
            await helper.handle(msg)
    finally:
        await helper.close_pairing()
        await helper.disconnect()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
