# Apostrophe AppImage

Self-contained AppImage build for [Apostrophe](https://gitlab.gnome.org/World/apostrophe),
a GTK4/libadwaita Markdown editor.

The build runs entirely inside a rootless Podman container. The host is not
modified and no distribution packages are installed on it.

See [BUILD-PROCESS.md](BUILD-PROCESS.md) for the complete end-to-end build
recipe, including every container stage and the issues that shaped it.

## Layout

```
.github/workflows/build.yml  CI: resolve upstream tag, build, test, release
build.sh                     Host driver: source checkout + container build
packaging/
  Containerfile.fedora44     Build image with compile/runtime dependencies
  inner-build.sh             Runs inside the container: build + assemble AppDir
  latest-tag.sh              Finds the newest upstream version tag
  bundle-libs.py             Copies the ELF dependency closure without glibc
  patch-webkit.py            Relocates WebKitGTK helper-process lookup
  patch-config.py            Makes installed Apostrophe paths relocatable
  AppRun                     Runtime environment and launcher
  test-appimage.sh           Clean-Fedora-44 smoke test
src/                         Apostrophe source checkout (created by build.sh)
tools/                       AppImage tooling (downloaded on first build)
work/fedora44/               Build tree, AppDir and temporary files
dist/                        Output AppImages
```

`src/`, `work/`, `tools/` and `dist/` are generated and git-ignored.

## Build

```bash
./build.sh fedora44
```

Produces `dist/Apostrophe-<version>-fedora44-x86_64.AppImage`.

The upstream tag is pinned to `v3.5` by default. Override it for another
release:

```bash
APOSTROPHE_TAG=v3.6 ./build.sh fedora44
```

`BASE_IMAGE` defaults to `quay.io/fedora/fedora:44`; set it to reuse another
Fedora 44 build image. Use `FORCE_IMAGE=1 ./build.sh fedora44` to rebuild the
Podman image when the `Containerfile` changes.

The output uses zstd level 19 (about 191 MB). Override the level with
`APPIMAGE_COMPRESS_LEVEL=<1-22>` if needed; the bundled `appimagetool` supports
only zstd.

## GitHub Actions

`.github/workflows/build.yml` runs on every push to `main`, weekly on a
schedule, and on demand. It:

1. Resolves the newest Apostrophe tag from `packaging/latest-tag.sh`.
2. Skips the build if a GitHub release for that tag already exists (scheduled
   runs only).
3. Builds and smoke-tests the AppImage in rootless Podman on the runner.
4. Publishes the AppImage and its SHA-256 as a GitHub release tagged with the
   upstream tag.

Use **Actions → Build Apostrophe AppImage → Run workflow** to build a specific
tag or force a rebuild.

The workflow installs Podman on the disposable GitHub runner only. Local builds
still use your existing rootless Podman and do not modify the host.

## Test

```bash
# Headless import/version check inside a clean Fedora 44 container
packaging/test-appimage.sh dist/Apostrophe-*-fedora44-x86_64.AppImage

# On a graphical host: start WebKit's helper processes and load a page
./dist/Apostrophe-*-fedora44-x86_64.AppImage --apostrophe-webkit-self-test

# Normal launch
./dist/Apostrophe-*-fedora44-x86_64.AppImage
```

## Portability model

Bundled:

- Python 3.14 (interpreter, standard library and extension modules),
  PyGObject, GTK4, libadwaita, GtkSourceView 5, libspelling, WebKitGTK 6.0.
- WebKit's helper processes (`WebKitWebProcess`, `WebKitNetworkProcess`,
  `WebKitGPUProcess`) and injected bundle, plus the `bwrap` and
  `xdg-dbus-proxy` helpers used by its sandbox.
- Glycin image loaders and their configuration, libproxy modules.
- GLib schemas, GIR typelibs, GdkPixbuf loaders, GIO modules, GtkSourceView
  language data, icons, fonts, translations and Hunspell dictionaries.
- Static upstream `pandoc` 3.12 and `typst` 0.15.1, and reveal.js 6.0.2.

Not bundled:

- glibc, the ELF loader and kernel-facing NSS libraries. The AppImage uses the
  host glibc and therefore needs a host at least as new as the build target.
- Graphics drivers (Mesa, Vulkan, libdrm). The host stack is used.

WebKitGTK 2.52+ removed `WEBKIT_EXEC_PATH`, so `patch-webkit.py` rewrites the
compiled-in helper directory, injected-bundle path, `/usr/bin/bwrap` and
`/usr/bin/xdg-dbus-proxy` strings to short fixed `/tmp` names. `AppRun`
re-points those symlinks at the current AppImage mount before launching.
`patch-config.py` rewrites Apostrophe's Meson-installed `/usr` paths to be
`$APPDIR`-relative at runtime.

## Caveats

- The fixed `/tmp` symlinks are per-user; a second user running a different
  Apostrophe AppImage at the same time is rejected with an explicit error.
- WebKit sandboxing requires unprivileged user namespaces, which are enabled by
  default on Fedora. Set `APOSTROPHE_NO_WEBKIT_SANDBOX=1` to disable it.
- `libenchant` provider lookup uses a compiled-in library directory. On a
  non-Fedora host without `enchant-2` in the matching location, spell checking
  may be unavailable even though dictionaries are bundled.
- Rendering issues with unusual GPU drivers can be worked around with
  `APOSTROPHE_DISABLE_DMABUF=1`.

An older-distribution target can be added next, now that the native Fedora 44
build is verified.
