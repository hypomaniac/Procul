#!/usr/bin/env python3
"""Searches an unpacked release for private strings, compressed parts included.

A release carries most of its text inside archives: zip files, and the
zlib streams PyInstaller packs Python modules into. A plain search of the
bytes on disk would sail past a private string hidden in either. This
opens all of it up, then prints every hit with the text around it, since
"line 12" means nothing inside a binary.

Usage: scan-release.py <folder> <fixed-strings-file> <regex-file>
Prints one line per finding. Prints nothing when the release is clean.
"""

import io
import os
import re
import sys
import zipfile
import zlib

ZLIB_SECOND_BYTES = {0x01, 0x5E, 0x9C, 0xDA}
MAX_DEPTH = 4
CONTEXT = 40


def inflate(data):
    """Every zlib stream found anywhere in the data, decompressed and joined."""
    out = []
    view = memoryview(data)
    position = data.find(b"\x78")
    while position != -1 and position + 1 < len(data):
        if data[position + 1] in ZLIB_SECOND_BYTES:
            stream = zlib.decompressobj()
            try:
                chunk = stream.decompress(view[position:])
            except zlib.error:
                chunk = b""
            if chunk and stream.eof:
                out.append(chunk)
                consumed = len(data) - position - len(stream.unused_data)
                position = data.find(b"\x78", position + max(consumed, 1))
                continue
        position = data.find(b"\x78", position + 1)
    return b"\n".join(out)


def layers(name, data, depth=0):
    """The data itself, then everything packed inside it."""
    yield name, data
    if depth >= MAX_DEPTH:
        return
    if data[:2] == b"PK":
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for member in archive.namelist():
                    if not member.endswith("/"):
                        yield from layers(f"{name} > {member}", archive.read(member), depth + 1)
        except (zipfile.BadZipFile, OSError, RuntimeError):
            pass
    inflated = inflate(data)
    if inflated:
        yield f"{name} > (inflated)", inflated


def load(fixed_path, regex_path):
    parts = []
    with open(fixed_path, encoding="utf-8") as handle:
        parts += [re.escape(line.rstrip("\n")) for line in handle if line.strip()]
    with open(regex_path, encoding="utf-8") as handle:
        parts += [line.rstrip("\n") for line in handle if line.strip()]
    return re.compile("|".join(f"(?:{part})" for part in parts).encode("utf-8"), re.IGNORECASE)


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    folder = sys.argv[1]
    pattern = load(sys.argv[2], sys.argv[3])
    seen = set()
    for root, _dirs, files in os.walk(folder):
        for filename in files:
            path = os.path.join(root, filename)
            if os.path.islink(path):
                continue
            with open(path, "rb") as handle:
                data = handle.read()
            for name, blob in layers(os.path.relpath(path, folder), data):
                for match in pattern.finditer(blob):
                    start = max(match.start() - CONTEXT, 0)
                    around = blob[start:match.end() + CONTEXT]
                    text = "".join(chr(b) if 32 <= b < 127 else "." for b in around)
                    line = f"zip: {name}: {text}"
                    if line not in seen:
                        seen.add(line)
                        print(line)


if __name__ == "__main__":
    main()
