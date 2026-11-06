# Apostrophe AppImage — Complete Build Process (Fedora 44)

This document describes the final, verified build process for the Apostrophe
AppImage. It covers the host-side driver, the Podman build image, every step
performed inside the container, the relocation strategy, and the tests used to
validate the result.

- **Application:** Apostrophe v3.5 (GTK4/libadwaita Markdown editor)
- **Build target:** Fedora 44, x86_64
- **Artifact:** `dist/Apostrophe-3.5-fedora44-x86_64.AppImage`
- **Size:** about 191 MB
- **Compression:** SquashFS, zstd level 19
- **Host policy:** everything runs in rootless Podman; no host packages are
  installed and no host files are modified.

---

## 1. Repository layout

```
build.sh                     Host driver: checkout, image, container run
.github/workflows/build.yml  CI: resolve tag, build, test, release
packaging/
  Containerfile.fedora44     Self-contained Fedora 44 build image
  inner-build.sh             Build + AppDir assembly, runs in the container
  latest-tag.sh              Finds the newest upstream version tag
  bundle-libs.py             ELF dependency closure (without glibc/NSS)
  patch-webkit.py            WebKitGTK helper-path relocation
  patch-config.py            Apostrophe /usr path relocation
  AppRun                     Runtime environment, launcher and self-tests
  test-appimage.sh           Clean-container smoke test
src/                         Pristine Apostrophe checkout (created by build.sh)
tools/                       appimagetool + runtime (cached)
work/fedora44/               Build tree, downloaded assets, AppDir
dist/                        Output AppImage
```

`src/`, `work/`, `tools/` and `dist/` are generated and git-ignored.

---

## 2. Prerequisites

On the build host:

- Fedora 44 (or a compatible host with the same or newer glibc)
- Rootless Podman
- Network access to Fedora mirrors and GitHub/GitLab release assets
- Enough disk for the build image, build tree, and a ~191 MB output

Nothing else is required on the host. The host glibc is deliberately used at
runtime; glibc and the ELF loader are never bundled.

---

## 3. Reproducing the build

```bash
cd apostrophe-appimage
./build.sh fedora44
```

Useful variants:

```bash
APOSTROPHE_TAG=v3.6 ./build.sh fedora44            # build another release
BASE_IMAGE=quay.io/fedora/fedora:44 \
  ./build.sh fedora44                              # choose the base image
FORCE_IMAGE=1 ./build.sh fedora44                  # rebuild the Podman image
APPIMAGE_COMPRESS_LEVEL=22 ./build.sh fedora44     # slower, slightly smaller
packaging/test-appimage.sh dist/Apostrophe-*-fedora44-x86_64.AppImage
```

The build is idempotent. The source checkout and the Podman image are reused;
downloaded assets (`reveal.js`, `pandoc`, `typst`, `appimagetool`, runtime) are
cached under `work/fedora44/` or `tools/`.

---

## 4. Host-side driver (`build.sh`)

`build.sh` performs only host-side orchestration:

1. Selects the Fedora 44 target and image names.
2. Clones the requested tag into `src/`, re-cloning when the existing checkout
   is at a different tag.
3. Creates `work/fedora44/`, `dist/` and `tools/`.
4. Downloads `appimagetool` and the type-2 runtime into `tools/` when missing.
5. Copies the pristine checkout to `work/fedora44/src` and removes `.git`.
   All generated files stay in the disposable copy, so a later run never
   inherits Meson or Python build products.
6. Reuses `localhost/apostrophe-build:fedora44` when it exists. Rebuilds it
   from `packaging/Containerfile.fedora44` only when `FORCE_IMAGE=1` or when
   the image is missing.
7. Starts the build container with the repository mounted at `/work`, passing
   `DISTRO`, `NAME`, `SRC`, `WORK`, `OUT`, `PACKAGING` and `TOOLS`.
8. Runs `packaging/inner-build.sh` inside the container.
9. Prints the contents of `dist/`.

The container is run with `--network=host` (package downloads and release
assets) and `--security-opt label=disable` (SELinux-friendly bind mount), and
the repository is mounted with `:Z`.

---

## 5. Build image (`packaging/Containerfile.fedora44`)

The image starts from the official Fedora 44 base:

```dockerfile
ARG BASE_IMAGE=quay.io/fedora/fedora:44
FROM ${BASE_IMAGE}
```

### 5.1 Fedora repository fix

The container environment cannot reach the hosts selected by Fedora's metalink
mirror list. The Containerfile therefore:

- disables `metalink=` in `fedora.repo` and `fedora-updates.repo`;
- points `baseurl=` at `https://dl.fedoraproject.org/pub/fedora/linux/...`;
- disables the Cisco OpenH264 repository.

### 5.2 Build and runtime packages

Installed in one layer with weak dependencies disabled:

- Build system: `meson`, `ninja-build`, `gcc`, `gcc-c++`, `make`,
  `pkgconf-pkg-config`, `git`.
- Python: `python3`, `python3-devel`, `python3-pip`, plus PyGObject, Cairo,
  regex and chardet bindings.
- GTK stack: `gtk4-devel`, `libadwaita-devel`, `gtksourceview5-devel`,
  `libspelling-devel`, `webkitgtk6.0-devel`, GLib and GObject-Introspection
  development packages.
- Packaging/metadata: `appstream`, `desktop-file-utils`, `gettext`,
  `libxml2-devel`, `gdk-pixbuf2`, `shared-mime-info`, `fontconfig`,
  `hicolor-icon-theme`, `adwaita-icon-theme`.
- Tooling: `patchelf`, `file`, `wget`, `curl`, `tar`, `xz`, `which`,
  `hostname`, `binutils`, `findutils`.
- Runtime helpers: `glibc-langpack-en`, `dbus-daemon`, `bubblewrap`.

A second layer adds runtime pieces that weak dependencies would otherwise omit:
`glib-networking`, `ca-certificates`, `gsettings-desktop-schemas`, `libproxy`,
`enchant2`.

A third layer installs optional content one package at a time so a missing
optional package cannot break the build:

- Hunspell English dictionaries and `enchant2-hunspell`
- Fira Sans and Fira Mono fonts
- `python3-levenshtein`

`librsvg2-tools` is installed separately to rasterize the application icon into
a PNG `.DirIcon`.

Pandoc, Typst and Xvfb are intentionally **not** installed from RPM. Pandoc and
Typst are fetched as pinned upstream static builds; Xvfb belongs to a separate
test image.

---

## 6. Build sequence inside the container (`inner-build.sh`)

The inner script is the authoritative build recipe. It runs these stages in
order:

1. `build_app`
2. `install_revealjs`
3. `bundle_python`
4. `patch_paths`
5. `bundle_data`
6. `bundle_webkit`
7. `bundle_tools`
8. `bundle_elf`
9. `install_metadata`
10. `make_appimage`

Each stage is described below.

### 6.1 Build and install Apostrophe (`build_app`)

```bash
meson setup "$BUILD" "$SRC" --prefix=/usr --buildtype=release
ninja -C "$BUILD"
DESTDIR="$APPDIR" ninja -C "$BUILD" install
```

`$APPDIR` is `work/fedora44/AppDir`. The Meson build directory is cleared on
every run so no stale generated files survive.

### 6.2 reveal.js (`install_revealjs`)

Apostrophe's HTML slideshow export needs reveal.js. The build downloads
reveal.js **6.0.2** from GitHub, installs it under
`$APPDIR/usr/share/apostrophe/libs/reveal.js`, then removes development-only
trees:

- `examples/` (about 5 MB by itself)
- `test/`
- `react/`
- `scripts/`
- `demo.html`
- `package-lock.json`

### 6.3 Python runtime (`bundle_python`)

The AppImage ships a complete Python **3.14** runtime so it does not depend on
the host's Python:

- The real `python3` executable is copied as `/usr/bin/python3.14`, with
  `python3` and `python` symlinks.
- `/usr/lib64/python3.14` is copied (extension modules).
- The standard library from `/usr/lib/python3.14` is copied, deliberately
  excluding `site-packages`.
- Only the third-party runtime modules Apostrophe imports (`chardet`,
  `pypandoc`) are copied into the bundle's `site-packages`.
- Build-only standard-library parts are removed:
  `test`, `idlelib`, `tkinter`, `ensurepip`, `lib2to3`, `config-*`.
- `libpython3.14.so*` is copied early so the bundled interpreter can be tested.
- `gdk-pixbuf-query-loaders`, `gio-querymodules` and `glib-compile-schemas` are
  installed under their canonical names. Fedora's `-64` spellings are resolved
  when present.

### 6.4 Relocate installed paths (`patch_paths` / `patch-config.py`)

Meson writes absolute `/usr` paths into Apostrophe's `config.py` and into the
`usr/bin/apostrophe` launcher. `patch-config.py` rewrites them to use `$APPDIR`
at runtime:

- `config.py` keys: `DATA_DIR`, `PKGDATA_DIR`, `LOCALE_DIR`, `LOCALEDIR`,
  `PYTHON_DIR`, `SCHEMAS_DIR`.
- The launcher's `sys.path` entry for the bundled `site-packages`.
- The launcher's `pkgdatadir` and `localedir`.

A small header is inserted into `config.py`:

```python
import os as _apostrophe_os
_APOSTROPHE_APPDIR = _apostrophe_os.environ.get('APPDIR', '')
def _apostrophe_path(rel):
    return _apostrophe_os.path.join(_APOSTROPHE_APPDIR, rel) \
        if _APOSTROPHE_APPDIR else _apostrophe_os.path.join('/', rel)
```

### 6.5 GObject/GTK data (`bundle_data`)

Bundled into the AppDir:

- GSettings schemas (copied and recompiled with `glib-compile-schemas`).
- GIR typelibs from `girepository-1.0`.
- `hicolor`, `Adwaita` and `Adwaita-dark` icon themes.
- GtkSourceView 5 language data.
- Spell-check data: `enchant-2`, `libspelling-1`, `hunspell`, `myspell`, and
  the `enchant-2` provider modules.
- GdkPixbuf loaders.
- GIO modules, indexed with `gio-querymodules` when available.
- GTK 4 modules.
- Apostrophe translations (`apostrophe.mo` only).
- Fira Sans/Fira Mono font directories.

### 6.6 WebKitGTK helpers and sandbox data (`bundle_webkit`)

WebKitGTK spawns helper processes and loads an injected bundle. The build:

- Finds the helper directory at one of the Fedora/upstream spellings
  (`webkitgtk-6.0` or `webkit2gtk-6.0`) and copies it to
  `$APPDIR/usr/libexec/<name>`.
- Copies WebKit's library/share data directories.
- Installs `bwrap` and `xdg-dbus-proxy` into `$APPDIR/usr/bin`.
- Copies Glycin image loaders and loader configuration; the configuration
  files' hardcoded `/usr/libexec/glycin-loaders` is rewritten to
  `/tmp/.apos-glycin`.
- Copies libproxy modules.

### 6.7 External tools (`bundle_tools`)

Pinned static upstream binaries are used instead of distribution packages:

- **pandoc 3.12** (`pandoc-3.12-linux-amd64.tar.gz`) installed as
  `$APPDIR/usr/bin/pandoc`.
- **typst 0.15.1** (`typst-x86_64-unknown-linux-musl.tar.xz`) installed as
  `$APPDIR/usr/bin/typst`.
- `/usr/share/pandoc` data files.

Using static builds avoids pulling a large Haskell shared-library closure (for
pandoc) or a Rust library closure (for typst).

### 6.8 ELF closure and RPATHs (`bundle_elf`)

`bundle-libs.py` walks every ELF file in the AppDir and copies the recursive
`ldd` dependency closure into `$APPDIR/usr/lib`. It also takes Python's
`lib-dynload` and `site-packages` directories as extra seed roots so extension
modules are included.

The blacklist is critical:

```
libc.*  libm.*  libpthread.*  libdl.*  librt.*  libresolv.*
libnss_*  libutil.*  libanl.*  libBrokenLocale.*  libmvec.*
ld-linux*  linux-vdso*  libc_malloc_debug
```

These must come from the host so the AppImage remains compatible with the
host kernel and glibc.

`set_rpaths` then rewrites every dynamic executable and shared object outside
`usr/lib` to use `$ORIGIN`-relative `usr/lib` and `usr/lib64` paths. Static
binaries are skipped:

- `usr/bin/pandoc` and `usr/bin/typst` are excluded explicitly;
- files without a `DT_NEEDED` entry are skipped;
- executables without `PT_INTERP` (static PIE) are skipped because `patchelf`
  cannot rewrite them safely.

### 6.9 WebKit helper relocation (`patch-webkit.py`)

WebKitGTK 2.52+ removed `WEBKIT_EXEC_PATH`; the helper directory is a plain
string compiled into `libwebkitgtk-6.0.so`. `patch-webkit.py` performs
equal-or-shorter, NUL-padded replacements so no ELF offsets move:

| Original | Replacement |
|---|---|
| `/usr/libexec/webkitgtk-6.0` | `/tmp/.apos-wk-exec` |
| `.../webkitgtk-6.0/injected-bundle/` | `/tmp/.apos-wk-libs/injected-bundle/` |
| `/usr/bin/bwrap` | `/tmp/.ap-bwrap` |
| `/usr/bin/xdg-dbus-proxy` | `/tmp/.apos-wk-dbus` |

Both Fedora (`webkitgtk-6.0`) and upstream/Debian (`webkit2gtk-6.0`) spellings
are matched. The script fails the build if no WebKit path could be relocated.

### 6.10 Metadata (`install_metadata`)

- Copies the application `.desktop` file to the AppDir root.
- Copies the application SVG icon and rasterizes a 256×256 PNG with
  `rsvg-convert` (or ImageMagick as fallback).
- Creates `.DirIcon` as a symlink to the PNG.
- Installs `packaging/AppRun` as executable.

### 6.11 AppImage packaging (`make_appimage`)

- Version is read from `meson.build`.
- Output name: `Apostrophe-<version>-fedora44-x86_64.AppImage`.
- Compression is zstd level 19 by default. The bundled `appimagetool` includes
  a minimal `mksquashfs` that supports only zstd, so other compressors are not
  used.
- The cached `tools/appimagetool-x86_64.AppImage` is used when present;
  otherwise it is downloaded.

---

## 7. Runtime design (`AppRun`)

`AppRun` resolves the mount from its own real path (ignoring a stale `APPDIR`)
and exports:

- `PATH` with `$APPDIR/usr/bin` first
- `LD_LIBRARY_PATH` with `usr/lib` and `usr/lib64`
- `PYTHONHOME`, `PYTHONPATH`, `PYTHONNOUSERSITE=1`
- `GI_TYPELIB_PATH`
- `GSETTINGS_SCHEMA_DIR`
- `XDG_DATA_DIRS`
- `GIO_MODULE_DIR`, `GTK_PATH`
- `DICPATH` (Hunspell/myspell dictionaries)
- `PYPANDOC_PANDOC` and `TYPST_FONT_PATHS`

### 7.1 Fixed-path symlinks

WebKitGTK's relocated strings point at fixed `/tmp` paths. `AppRun` creates
those symlinks for the current mount:

- `/tmp/.apos-wk-exec` → bundled WebKit helper directory
- `/tmp/.apos-wk-libs` → bundled WebKit library/injected-bundle directory
- `/tmp/.ap-bwrap` → bundled `bwrap`
- `/tmp/.apos-wk-dbus` → bundled `xdg-dbus-proxy`
- `/tmp/.apos-glycin` → bundled Glycin loaders

The `link_fixed` helper refuses to overwrite an existing non-symlink or a
symlink owned by a different user. This makes concurrent AppImage mounts from
different users fail with a clear message instead of silently redirecting.

### 7.2 GdkPixbuf loader cache

The loader cache contains absolute paths, so it is generated per mount at
runtime and stored under the user's cache directory, keyed by a checksum of the
mount path. gdk-pixbuf 2.44 has built-in loaders and ships no modules, in which
case cache generation is skipped.

### 7.3 Self-tests

`AppRun` implements two commands used by the test suite:

- `--apostrophe-self-test`: imports GI namespaces (Gtk, Adw, GtkSource,
  Spelling, WebKit 6.0), checks `chardet`, `pypandoc`, and the bundled Typst
  version. This runs headlessly.
- `--apostrophe-webkit-self-test`: starts a GTK application with a WebKit view,
  loads an HTML page containing an image, and exits successfully when the load
  finishes. This validates helper-process spawning, the injected bundle, the
  sandbox helper paths, and image decoding.

Optional runtime workarounds:

- `APOSTROPHE_NO_WEBKIT_SANDBOX=1` disables WebKit's sandbox.
- `APOSTROPHE_DISABLE_DMABUF=1` disables the DMABUF renderer.

---

## 8. Testing

### 8.1 Clean-container test

```bash
packaging/test-appimage.sh dist/Apostrophe-*-fedora44-x86_64.AppImage
```

This runs the AppImage inside a pristine `quay.io/fedora/fedora:44` container
with no GTK, WebKit or Python packages installed, using
`APPIMAGE_EXTRACT_AND_RUN=1`. It executes `--apostrophe-self-test`.

### 8.2 WebKit test on a graphical host

```bash
./dist/Apostrophe-*-fedora44-x86_64.AppImage --apostrophe-webkit-self-test
```

This loads a page and an image through WebKitGTK, exercising the relocated
helper paths.

### 8.3 Normal launch

```bash
./dist/Apostrophe-*-fedora44-x86_64.AppImage
```

Expected: the GTK4 window opens with no Python tracebacks.

---

## 9. What is bundled, and what is not

Bundled:

- Python 3.14 interpreter, standard library and required extension modules
- PyGObject, GTK4, libadwaita, GtkSourceView 5, libspelling, WebKitGTK 6.0
- WebKit helper processes and injected bundle
- `bwrap`, `xdg-dbus-proxy`, Glycin loaders, libproxy modules
- GLib schemas, GIR typelibs, GdkPixbuf loaders, GIO modules, GTK modules
- GtkSourceView language data, icons, Fira fonts, translations, Hunspell data
- Static pandoc 3.12, static typst 0.15.1, reveal.js 6.0.2

Not bundled:

- glibc, the ELF loader, NSS libraries (host-provided)
- Mesa/Vulkan/libdrm graphics drivers (host-provided)

---

## 10. Problems encountered and how the final build solves them

- **Unreachable Fedora metalink mirrors** — disable metalink and use the
  canonical `dl.fedoraproject.org` base URLs.
- **WebKitGTK 2.52+ removed `WEBKIT_EXEC_PATH`** — patch the compiled-in
  helper and injected-bundle strings with equal-or-shorter fixed `/tmp` names.
- **Glycin loader configuration hardcodes `/usr/libexec/glycin-loaders`** —
  rewrite the bundled configuration and point a fixed symlink at the packaged
  loaders.
- **Static PIE tools cannot be patched by `patchelf`** — explicitly skip
  `pandoc` and `typst`, and skip executables without `PT_INTERP`.
- **`appimagetool` only supports zstd** — use zstd level 19 for a smaller
  image at acceptable build time.
- **Host Python contamination** — bundle a private Python with
  `PYTHONHOME`, `PYTHONPATH`, and `PYTHONNOUSERSITE=1`.
- **Fixed `/tmp` links can collide between users** — `link_fixed` checks link
  ownership and fails with a clear error instead of overwriting.

---

## 11. Final artifact

```
dist/Apostrophe-3.5-fedora44-x86_64.AppImage
Size:  ~191 MB
Format: AppImage type 2, SquashFS + zstd level 19
```

Verified on Fedora 44:

- clean-container `--apostrophe-self-test` passes;
- WebKit preview self-test loads a page and an image;
- the GTK4 window launches without Python tracebacks.
