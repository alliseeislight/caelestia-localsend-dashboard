#!/usr/bin/env python3
"""Idempotently wire the LocalSend dashboard tab into Caelestia's Content.qml.

Usage: patch-content.py /path/to/Content.qml

The script:
  * adds a tab entry to the ``dashboardTabs`` array, and
  * adds the ``Component { id: localSendComponent; LocalSendTab {} }`` block.

It detects an already-patched file and does nothing, so it is safe to re-run.
A timestamped backup is made by the caller (install.sh), not here.
"""
from __future__ import annotations

import pathlib
import re
import sys


def build_block(lines: list[str], indent: int) -> str:
    pad = " " * indent
    return "\n".join(pad + line if line.strip() else "" for line in lines)


def patch(src: str) -> str:
    if "localSendComponent" in src:
        raise AlreadyPatched

    # -- 1. tab entry, inserted just before the dashboardTabs array close ----
    anchor = "dashboardTabs"
    ai = src.find(anchor)
    if ai == -1:
        raise PatchError("could not find the `dashboardTabs` property")
    term = src.find("];", ai)
    if term == -1:
        raise PatchError("could not find the end of the dashboardTabs array")
    line_start = src.rfind("\n", 0, term) + 1
    term_indent = term - line_start  # spaces before `];`
    item_indent = term_indent + 4
    entry = build_block(
        [
            "{",
            "    component: localSendComponent,",
            '    iconName: "wifi_tethering",',
            '    text: Tr.tr("LocalSend"),',
            "    enabled: true",
            "}",
        ],
        item_indent,
    )
    # Ensure the previous array element is comma-terminated before we append.
    base = src[:line_start].rstrip()
    if not base.endswith(","):
        base += ","
    src = base + "\n" + entry + "\n" + src[line_start:]

    # -- 2. Component block, inserted before the content Behavior ------------
    m = re.search(r"\n([ \t]*)Behavior on contentX\s*\{", src)
    if not m:
        raise PatchError("could not find the `Behavior on contentX` insertion point")
    comp_indent = len(m.group(1))
    component = build_block(
        [
            "Component {",
            "    id: localSendComponent",
            "",
            "    LocalSendTab {}",
            "}",
        ],
        comp_indent,
    )
    src = src[: m.start()] + "\n" + component + "\n" + src[m.start():]
    return src


class AlreadyPatched(Exception):
    pass


class PatchError(Exception):
    pass


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    path = pathlib.Path(argv[1])
    src = path.read_text(encoding="utf-8")
    try:
        out = patch(src)
    except AlreadyPatched:
        print("Content.qml already contains the LocalSend tab; nothing to do.")
        return 0
    except PatchError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    path.write_text(out, encoding="utf-8")
    print("Content.qml patched.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
