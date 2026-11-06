#!/usr/bin/env python3
"""Redirect WebKitGTK's compiled-in helper-process paths into the AppImage.

WebKitGTK spawns WebKitWebProcess / WebKitNetworkProcess / WebKitGPUProcess as
separate executables and loads an injected bundle.  Newer releases (2.52+)
removed WEBKIT_EXEC_PATH, so the directory is a plain string baked into
libwebkitgtk at build time.  We replace two NUL-terminated strings:

  /usr/libexec/webkitgtk-6.0            -> /tmp/.apos-wk-exec
  /usr/lib64/webkitgtk-6.0/injected-bundle/ -> /tmp/.apos-wk-libs/injected-bundle/

AppRun creates the fixed /tmp symlinks pointing at the bundled copies.
Replacements are always shorter and NUL-padded, so no ELF offsets move.

Both Fedora's "webkitgtk-6.0" and the upstream/Debian "webkit2gtk-6.0"
spelling are handled.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

DEFAULT_EXEC = b"/tmp/.apos-wk-exec"
DEFAULT_LIBS = b"/tmp/.apos-wk-libs"
DEFAULT_BWRAP = b"/tmp/.ap-bwrap"
DEFAULT_DBUS = b"/tmp/.apos-wk-dbus"

EXEC_RE = re.compile(
    rb"(/[A-Za-z0-9_./+-]*/webkit(?:2)?gtk-6\.0)\x00"
)
BUNDLE_RE = re.compile(
    rb"(/[A-Za-z0-9_./+-]*/webkit(?:2)?gtk-6\.0)/injected-bundle/\x00"
)
BWRAP_RE = re.compile(rb"/usr/bin/bwrap\x00")
DBUS_RE = re.compile(rb"/usr/bin/xdg-dbus-proxy\x00")


def replace_padded(blob: bytes, pattern: re.Pattern[bytes], replacement: bytes,
                   with_suffix: bytes) -> tuple[bytes, int]:
    count = 0

    def repl(m: re.Match[bytes]) -> bytes:
        nonlocal count
        original = m.group(0)
        new = replacement + with_suffix + b"\x00"
        if len(new) > len(original):
            return original
        count += 1
        return new + b"\0" * (len(original) - len(new))

    return pattern.sub(repl, blob), count


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("appdir", type=Path)
    ap.add_argument("--exec-replacement", default=DEFAULT_EXEC.decode())
    ap.add_argument("--libs-replacement", default=DEFAULT_LIBS.decode())
    ap.add_argument("--bwrap-replacement", default=DEFAULT_BWRAP.decode())
    ap.add_argument("--dbus-replacement", default=DEFAULT_DBUS.decode())
    args = ap.parse_args()

    appdir = args.appdir.resolve()
    exec_repl = args.exec_replacement.encode()
    libs_repl = args.libs_replacement.encode()
    bwrap_repl = args.bwrap_replacement.encode()
    dbus_repl = args.dbus_replacement.encode()

    candidates = sorted(appdir.glob("usr/lib*/libwebkitgtk-6.0.so*"))
    if not candidates:
        print("error: bundled libwebkitgtk-6.0.so not found", file=sys.stderr)
        return 1

    total = 0
    for lib in candidates:
        if lib.is_symlink():
            continue
        blob = lib.read_bytes()
        if b"webkit" not in blob:
            continue

        # The injected bundle lives under the library directory, so patch it
        # first; afterwards only the helper-executable directory remains.
        blob, n_bundle = replace_padded(
            blob, BUNDLE_RE, libs_repl, b"/injected-bundle/"
        )
        blob, n_exec = replace_padded(blob, EXEC_RE, exec_repl, b"")
        blob, n_bwrap = replace_padded(blob, BWRAP_RE, bwrap_repl, b"")
        blob, n_dbus = replace_padded(blob, DBUS_RE, dbus_repl, b"")
        if n_bundle + n_exec + n_bwrap + n_dbus == 0:
            print(f"warning: no WebKit helper paths found in {lib}",
                  file=sys.stderr)
            continue

        lib.write_bytes(blob)
        os.chmod(lib, 0o755)
        total += n_bundle + n_exec + n_bwrap + n_dbus
        print(
            f"patched WebKit paths in {lib} "
            f"(exec={n_exec}, bundle={n_bundle}, "
            f"bwrap={n_bwrap}, dbus={n_dbus})"
        )

    if total == 0:
        print("error: WebKit helper paths could not be relocated", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
