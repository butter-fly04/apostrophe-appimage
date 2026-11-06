#!/usr/bin/env python3
"""Make Apostrophe's installed absolute paths work from an AppImage mount.

The Meson install writes /usr/share, /usr/share/apostrophe and similar paths
into config.py.  An AppImage is mounted at a random directory, so those need to
be resolved relative to $APPDIR at runtime.  The launcher script is patched for
the same reason.
"""
from __future__ import annotations

import argparse
import os
import re
import stat
from pathlib import Path

KEYS = (
    "DATA_DIR",
    "PKGDATA_DIR",
    "LOCALE_DIR",
    "LOCALEDIR",
    "PYTHON_DIR",
    "SCHEMAS_DIR",
)


HEADER = (
    "import os as _apostrophe_os\n"
    "_APOSTROPHE_APPDIR = _apostrophe_os.environ.get('APPDIR', '')\n"
    "def _apostrophe_path(rel):\n"
    "    return _apostrophe_os.path.join(_APOSTROPHE_APPDIR, rel) "
    "if _APOSTROPHE_APPDIR else _apostrophe_os.path.join('/', rel)\n"
)


def patch_config(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text

    if "_APOSTROPHE_APPDIR" not in text:
        # Insert after the module docstring / future imports.
        lines = text.splitlines(keepends=True)
        insert_at = 0
        for i, line in enumerate(lines):
            if line.startswith(("import ", "from ")) or line.startswith("#"):
                insert_at = i + 1
                break
        else:
            insert_at = 0
        lines.insert(insert_at, HEADER)
        text = "".join(lines)
    else:
        # Repair the fallback used by an earlier version of this script.
        text = text.replace(
            "_apostrophe_os.path.join('/usr', rel)",
            "_apostrophe_os.path.join('/', rel)",
        )

    for key in KEYS:
        m = re.search(
            rf"^{re.escape(key)}\s*=\s*(['\"])([^'\"]+)\1\s*$",
            text,
            re.MULTILINE,
        )
        if m:
            value = m.group(2)
            if value == "/usr":
                rel = "usr"
            elif value.startswith("/usr/"):
                rel = "usr/" + value[len("/usr/"):]
            else:
                continue
            replacement = f"{key} = _apostrophe_path({rel!r})"
            text = text[: m.start()] + replacement + text[m.end():]
            continue

        # Already patched, but possibly without the leading "usr/".
        m = re.search(
            rf"^{re.escape(key)}\s*=\s*_apostrophe_path\((['\"])([^'\"]+)\1\)\s*$",
            text,
            re.MULTILINE,
        )
        if not m:
            continue
        rel = m.group(2).lstrip("/")
        if rel in ("", "."):
            rel = "usr"
        elif not rel.startswith("usr/"):
            rel = "usr/" + rel
        else:
            continue
        replacement = f"{key} = _apostrophe_path({rel!r})"
        text = text[: m.start()] + replacement + text[m.end():]

    if text != original:
        path.write_text(text, encoding="utf-8")
        return True
    return False


def patch_launcher(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    original = text

    if "import os" not in text and "import os as " not in text:
        text = re.sub(r"^(#!.*\n)", r"\1import os\n", text, count=1)

    # sys.path.insert(..., '/usr/lib64/pythonX.Y/site-packages')
    text = re.sub(
        r"(['\"])/usr/(lib(?:64)?/python[^'\"]*/site-packages)\1",
        r"os.path.join(os.environ.get('APPDIR', '/'), 'usr/\2')",
        text,
    )

    # pkgdatadir = '/usr/share/apostrophe'
    # localedir = '/usr/share/locale'
    text = re.sub(
        r"^(\s*)(pkgdatadir|localedir)\s*=\s*(['\"])/usr/([^'\"]+)\3\s*$",
        r"\1\2 = os.path.join(os.environ.get('APPDIR', '/'), 'usr/\4')",
        text,
        flags=re.MULTILINE,
    )

    if text != original:
        path.write_text(text, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("appdir", type=Path)
    args = ap.parse_args()

    appdir = args.appdir.resolve()
    changed = 0

    for config in appdir.glob("usr/lib*/python*/site-packages/apostrophe/config.py"):
        if patch_config(config):
            print(f"patched {config}")
            changed += 1

    launcher = appdir / "usr/bin/apostrophe"
    if launcher.exists() and patch_launcher(launcher):
        print(f"patched {launcher}")
        changed += 1

    if changed == 0:
        print("warning: no Apostrophe paths needed patching", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
