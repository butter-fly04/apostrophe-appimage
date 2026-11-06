# Native Fedora 44 build

Builds an AppImage of Apostrophe v3.5 inside a rootless Podman container.

## Status

Verified on Fedora 44.

- Clean Fedora 44 container self-test passes with no GTK/WebKit packages
  installed (`--apostrophe-self-test`).
- WebKit preview self-test loads a page and image on a graphical host
  (`--apostrophe-webkit-self-test`).
- The application launches its GTK4 window without Python tracebacks.

Artifact: `dist/Apostrophe-3.5-fedora44-x86_64.AppImage` (about 191 MB).

## Run

```bash
cd apostrophe-appimage
./build.sh fedora44
packaging/test-appimage.sh dist/Apostrophe-*-fedora44-x86_64.AppImage
./dist/Apostrophe-*-fedora44-x86_64.AppImage
```

Set `APOSTROPHE_TAG=v3.6` to build another release, and `FORCE_IMAGE=1`
when the build image itself needs to be rebuilt.

## Design notes

- The AppImage bundles the Python 3.14 runtime, PyGObject, GTK4, libadwaita,
  GtkSourceView 5, libspelling and WebKitGTK 6.0.
- glibc and the ELF loader are **not** bundled.
- WebKitGTK 2.54 removed `WEBKIT_EXEC_PATH`; `patch-webkit.py` rewrites the
  compiled-in helper directory, injected-bundle path, `bwrap` and
  `xdg-dbus-proxy` strings to fixed `/tmp` names, and `AppRun` creates the
  matching symlinks for the current mount.
- The injected bundle, helper executables and bundled libraries carry
  `$ORIGIN`-relative RPATHs, so they still resolve after WebKit's sandbox
  starts them with a modified environment.
- `patch-config.py` rewrites Apostrophe's Meson-configured `/usr/share` and
  Python site-packages paths to be `$APPDIR`-relative at runtime.
- `bundle-libs.py` walks the ELF closure with `ldd` while explicitly refusing
  to copy glibc and NSS components.
- Pandoc and Typst are always the pinned upstream static builds, not
  distribution packages, so no Haskell or Rust library closure is pulled in.
