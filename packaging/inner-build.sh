#!/usr/bin/env bash
# Runs inside the Fedora build container.  Builds Apostrophe, assembles a
# relocatable AppDir, bundles the runtime closure and produces an AppImage.
set -euo pipefail

: "${DISTRO:?}"
: "${NAME:?}"
: "${SRC:?}"
: "${WORK:?}"
: "${OUT:?}"
: "${PACKAGING:?}"
: "${TOOLS:?}"

export LC_ALL=C.UTF-8
export APPIMAGE_EXTRACT_AND_RUN=1

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning: %s\033[0m\n' "$*" >&2; }

APPDIR="$WORK/AppDir"
BUILD="$WORK/build"
PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

copy_dir() {
  local src="$1" dst="$2"
  if [ -d "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

# Fedora ships some GLib helpers with a -64 suffix (gdk-pixbuf-query-loaders-64,
# gio-querymodules-64).  Resolve either spelling.
find_tool() {
  local name
  for name in "$@"; do
    if command -v "$name" >/dev/null 2>&1; then
      command -v "$name"
      return 0
    fi
  done
  return 1
}

find_webkit_helper_dir() {
  for d in /usr/libexec/webkitgtk-6.0 /usr/libexec/webkit2gtk-6.0 \
           /usr/lib64/webkitgtk-6.0 /usr/lib64/webkit2gtk-6.0 \
           /usr/lib/webkitgtk-6.0 /usr/lib/webkit2gtk-6.0; do
    if [ -d "$d" ] && [ -x "$d/WebKitWebProcess" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Build and install Apostrophe
# ---------------------------------------------------------------------------
build_app() {
  log "Configuring Apostrophe"
  rm -rf "$BUILD"
  meson setup "$BUILD" "$SRC" \
    --prefix=/usr \
    --buildtype=release

  log "Compiling"
  ninja -C "$BUILD"

  log "Installing into AppDir"
  rm -rf "$APPDIR"
  mkdir -p "$APPDIR"
  DESTDIR="$APPDIR" ninja -C "$BUILD" install
}

# ---------------------------------------------------------------------------
# reveal.js (used by the HTML slideshow export)
# ---------------------------------------------------------------------------
install_revealjs() {
  local version="6.0.2"
  local archive="$WORK/reveal.js-$version.tar.gz"
  local dir="$WORK/reveal.js-$version"

  if [ ! -d "$dir" ]; then
    log "Downloading reveal.js $version"
    curl -fL --retry 3 -o "$archive" \
      "https://github.com/hakimel/reveal.js/archive/refs/tags/$version.tar.gz"
    mkdir -p "$dir"
    tar -xzf "$archive" -C "$dir" --strip-components=1
  fi

  log "Installing reveal.js"
  install -d "$APPDIR/usr/share/apostrophe/libs"
  rm -rf "$APPDIR/usr/share/apostrophe/libs/reveal.js"
  cp -a "$dir" "$APPDIR/usr/share/apostrophe/libs/reveal.js"

  # Apostrophe copies this whole directory into every slideshow export.  Only
  # the runtime assets are needed; examples, tests and development files are
  # not, and examples/assets alone is about 5 MB.
  local rjs="$APPDIR/usr/share/apostrophe/libs/reveal.js"
  rm -rf "$rjs/examples" "$rjs/test" "$rjs/react" "$rjs/scripts"
  rm -f "$rjs/demo.html" "$rjs/package-lock.json"
}

# ---------------------------------------------------------------------------
# Python runtime
# ---------------------------------------------------------------------------
bundle_python() {
  log "Bundling Python $PYVER"
  local pybin
  pybin="$(readlink -f "$(command -v python3)")"

  install -d "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/lib64"
  cp -a "$pybin" "$APPDIR/usr/bin/python$PYVER"
  ln -sfn "python$PYVER" "$APPDIR/usr/bin/python3"
  ln -sfn "python$PYVER" "$APPDIR/usr/bin/python"

  if [ -d "/usr/lib64/python$PYVER" ]; then
    cp -a "/usr/lib64/python$PYVER" "$APPDIR/usr/lib64/"
  fi
  if [ -d "/usr/lib/python$PYVER" ]; then
    # Copy the standard library, but not the distribution's site-packages:
    # that directory also holds build tooling (pip, setuptools, Meson) which
    # has no place in the runtime bundle.
    mkdir -p "$APPDIR/usr/lib/python$PYVER"
    local entry
    for entry in "/usr/lib/python$PYVER"/*; do
      [ "$(basename "$entry")" = "site-packages" ] && continue
      cp -a "$entry" "$APPDIR/usr/lib/python$PYVER/"
    done
    # Only the third-party modules Apostrophe actually imports at runtime.
    local site="/usr/lib/python$PYVER/site-packages"
    local dest="$APPDIR/usr/lib/python$PYVER/site-packages"
    mkdir -p "$dest"
    for entry in chardet pypandoc; do
      [ -d "$site/$entry" ] && cp -a "$site/$entry" "$dest/"
    done
  fi

  # The shared library is also pulled in by the ELF closure, but copy it early
  # so the interpreter can be tested before bundling.
  cp -a /usr/lib64/libpython"$PYVER".so* "$APPDIR/usr/lib/" 2>/dev/null || true

  # Strip things only useful for building Python itself.
  local pyroot="$APPDIR/usr/lib64/python$PYVER"
  if [ -d "$pyroot" ]; then
    rm -rf "$pyroot/test" "$pyroot/idlelib" "$pyroot/tkinter" \
           "$pyroot/ensurepip" "$pyroot/lib2to3" "$pyroot"/config-*
  fi

  # Copy the query helpers used at runtime under their canonical names.
  local tool
  if tool="$(find_tool gdk-pixbuf-query-loaders gdk-pixbuf-query-loaders-64)"; then
    install -Dm755 "$tool" "$APPDIR/usr/bin/gdk-pixbuf-query-loaders"
  else
    warn "gdk-pixbuf-query-loaders not found; loaders will be discovered from the host cache"
  fi
  if tool="$(find_tool gio-querymodules gio-querymodules-64)"; then
    install -Dm755 "$tool" "$APPDIR/usr/bin/gio-querymodules"
  else
    warn "gio-querymodules not found; GIO modules will be discovered from the host cache"
  fi
  if tool="$(find_tool glib-compile-schemas)"; then
    install -Dm755 "$tool" "$APPDIR/usr/bin/glib-compile-schemas"
  else
    warn "glib-compile-schemas not found; schemas were compiled during install"
  fi
}

patch_paths() {
  log "Making installed paths relocatable"
  python3 "$PACKAGING/patch-config.py" "$APPDIR"
}

# ---------------------------------------------------------------------------
# GTK / GObject data
# ---------------------------------------------------------------------------
bundle_data() {
  log "Bundling GSettings schemas"
  copy_dir /usr/share/glib-2.0/schemas "$APPDIR/usr/share/glib-2.0/schemas"
  glib-compile-schemas --targetdir="$APPDIR/usr/share/glib-2.0/schemas" \
    "$APPDIR/usr/share/glib-2.0/schemas"

  log "Bundling GIR typelibs"
  for d in /usr/lib64/girepository-1.0 /usr/lib/girepository-1.0; do
    [ -d "$d" ] && copy_dir "$d" "$APPDIR/usr/${d#/usr/}"
  done

  log "Bundling icons and themes"
  copy_dir /usr/share/icons/hicolor "$APPDIR/usr/share/icons/hicolor"
  copy_dir /usr/share/icons/Adwaita "$APPDIR/usr/share/icons/Adwaita"
  copy_dir /usr/share/icons/Adwaita-dark "$APPDIR/usr/share/icons/Adwaita-dark"

  log "Bundling GtkSourceView language data"
  copy_dir /usr/share/gtksourceview-5 "$APPDIR/usr/share/gtksourceview-5"

  log "Bundling spell-check data"
  copy_dir /usr/share/enchant-2 "$APPDIR/usr/share/enchant-2"
  copy_dir /usr/share/libspelling-1 "$APPDIR/usr/share/libspelling-1"
  copy_dir /usr/share/hunspell "$APPDIR/usr/share/hunspell"
  copy_dir /usr/share/myspell "$APPDIR/usr/share/myspell"
  copy_dir /usr/lib64/enchant-2 "$APPDIR/usr/lib64/enchant-2"

  log "Bundling GdkPixbuf loaders"
  copy_dir /usr/lib64/gdk-pixbuf-2.0 "$APPDIR/usr/lib64/gdk-pixbuf-2.0"

  log "Bundling GIO modules"
  copy_dir /usr/lib64/gio/modules "$APPDIR/usr/lib64/gio/modules"
  if [ -d "$APPDIR/usr/lib64/gio/modules" ]; then
    if tool="$(find_tool gio-querymodules gio-querymodules-64)"; then
      "$tool" "$APPDIR/usr/lib64/gio/modules" || true
    fi
  fi

  log "Bundling GTK modules"
  copy_dir /usr/lib64/gtk-4.0 "$APPDIR/usr/lib64/gtk-4.0"

  log "Bundling Apostrophe translations"
  if [ -d /usr/share/locale ]; then
    while IFS= read -r -d '' f; do
      rel="${f#/usr/share/locale/}"
      install -Dm644 "$f" "$APPDIR/usr/share/locale/$rel"
    done < <(find /usr/share/locale -path '*/LC_MESSAGES/apostrophe.mo' -print0)
  fi

  log "Bundling Fira fonts"
  while IFS= read -r -d '' f; do
    copy_dir "$f" "$APPDIR/usr/share/fonts/$(basename "$f")"
  done < <(find /usr/share/fonts -mindepth 1 -maxdepth 2 -type d -iname '*fira*' -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# WebKitGTK helper processes and data
# ---------------------------------------------------------------------------
bundle_webkit() {
  local helper_dir helper_name
  if ! helper_dir="$(find_webkit_helper_dir)"; then
    warn "WebKit helper directory not found"
    return 0
  fi

  helper_name="$(basename "$helper_dir")"
  log "Bundling WebKit helpers from $helper_dir"
  copy_dir "$helper_dir" "$APPDIR/usr/libexec/$helper_name"

  for d in /usr/lib64/webkitgtk-6.0 /usr/lib64/webkit2gtk-6.0 \
           /usr/lib/webkitgtk-6.0 /usr/lib/webkit2gtk-6.0 \
           /usr/share/webkitgtk-6.0 /usr/share/webkit2gtk-6.0; do
    [ -d "$d" ] && copy_dir "$d" "$APPDIR/usr/${d#/usr/}"
  done

  log "Bundling WebKit sandbox helpers"
  local tool tool_path
  for tool in bwrap xdg-dbus-proxy; do
    if tool_path="$(find_tool "$tool")"; then
      install -Dm755 "$tool_path" "$APPDIR/usr/bin/$tool"
    else
      warn "$tool not found; WebKit sandboxing will be disabled at runtime"
    fi
  done

  log "Bundling Glycin image loaders"
  copy_dir /usr/libexec/glycin-loaders "$APPDIR/usr/libexec/glycin-loaders"
  copy_dir /usr/share/glycin-loaders "$APPDIR/usr/share/glycin-loaders"
  if [ -d "$APPDIR/usr/share/glycin-loaders" ]; then
    # The loader configuration files hardcode the system loader directory.
    find "$APPDIR/usr/share/glycin-loaders" -name '*.conf' -exec \
      sed -i 's|/usr/libexec/glycin-loaders|/tmp/.apos-glycin|g' {} +
  fi

  log "Bundling libproxy modules"
  copy_dir /usr/lib64/libproxy "$APPDIR/usr/lib64/libproxy"
}

# ---------------------------------------------------------------------------
# Optional external tools
# ---------------------------------------------------------------------------
bundle_tools() {
  log "Bundling external tools"

  # Always use the pinned static builds: distribution pandoc packages pull in
  # a large Haskell shared-library closure and older versions.
  local version dir
  version="3.12"
  dir="$WORK/pandoc-$version"
  if [ ! -x "$dir/bin/pandoc" ]; then
    log "Downloading official pandoc $version"
    curl -fL --retry 3 -o "$WORK/pandoc.tar.gz" \
      "https://github.com/jgm/pandoc/releases/download/$version/pandoc-$version-linux-amd64.tar.gz"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xzf "$WORK/pandoc.tar.gz" -C "$dir" --strip-components=1
  fi
  install -Dm755 "$dir/bin/pandoc" "$APPDIR/usr/bin/pandoc"

  version="0.15.1"
  dir="$WORK/typst-$version"
  if [ ! -x "$dir/typst" ]; then
    log "Downloading official typst $version"
    curl -fL --retry 3 -o "$WORK/typst.tar.xz" \
      "https://github.com/typst/typst/releases/download/v$version/typst-x86_64-unknown-linux-musl.tar.xz"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xJf "$WORK/typst.tar.xz" -C "$dir" --strip-components=1
  fi
  install -Dm755 "$dir/typst" "$APPDIR/usr/bin/typst"

  copy_dir /usr/share/pandoc "$APPDIR/usr/share/pandoc"
}

# ---------------------------------------------------------------------------
# ELF closure and WebKit relocation
# ---------------------------------------------------------------------------
set_rpaths() {
  log "Setting relocatable RPATHs"
  local f dir rel_lib rel_lib64 is_so
  while IFS= read -r -d '' f; do
    # Skip the pinned static tools; they need no RPATH and some static-PIE
    # binaries cannot be rewritten by patchelf.
    case "$f" in
      */usr/bin/pandoc|*/usr/bin/typst) continue ;;
    esac
    # Only dynamic ELF objects; static binaries have no .dynamic.
    if ! readelf -d "$f" 2>/dev/null | grep -q 'NEEDED'; then
      continue
    fi
    # Executables need PT_INTERP; shared objects do not.  This skips
    # static-PIE binaries such as pandoc, which patchelf cannot rewrite.
    is_so=0
    case "$f" in
      *.so|*.so.*) is_so=1 ;;
    esac
    if [ "$is_so" = 0 ] && \
       ! readelf -l "$f" 2>/dev/null | grep -q 'INTERP'; then
      continue
    fi
    dir="$(dirname "$f")"
    rel_lib="$(realpath --relative-to="$dir" "$APPDIR/usr/lib")"
    rel_lib64="$(realpath --relative-to="$dir" "$APPDIR/usr/lib64")"
    patchelf --set-rpath "\$ORIGIN/$rel_lib:\$ORIGIN/$rel_lib64" "$f" \
      || warn "could not set RPATH on $f"
  done < <(find "$APPDIR/usr/bin" "$APPDIR/usr/libexec" \
                "$APPDIR/usr/lib64/webkitgtk-6.0" \
                "$APPDIR/usr/lib64/webkit2gtk-6.0" \
                -type f \( -perm -u+x -o -name '*.so' \) -print0 2>/dev/null)
}

bundle_elf() {
  log "Bundling ELF dependency closure"
  python3 "$PACKAGING/bundle-libs.py" "$APPDIR" \
    --seed-elf-dir "$APPDIR/usr/lib64/python$PYVER" \
    --seed-elf-dir "$APPDIR/usr/lib64/python$PYVER/site-packages"

  set_rpaths

  log "Relocating WebKit helper lookup"
  python3 "$PACKAGING/patch-webkit.py" "$APPDIR"
}

# ---------------------------------------------------------------------------
# AppImage metadata and packaging
# ---------------------------------------------------------------------------
install_metadata() {
  log "Preparing AppImage metadata"
  local desktop icon png icon_name
  desktop="$(find "$APPDIR/usr/share/applications" -name '*.desktop' | head -n1)"
  icon="$(find "$APPDIR/usr/share/icons" -type f \
      -name 'org.gnome.gitlab.somas.Apostrophe.svg' | head -n1)"
  if [ -z "$icon" ]; then
    icon="$(find "$APPDIR/usr/share/icons" -type f \
        -name 'org.gnome.gitlab.somas.Apostrophe.*' \
        ! -name '*-symbolic.*' | head -n1)"
  fi

  if [ -n "$desktop" ]; then
    cp "$desktop" "$APPDIR/"
  else
    warn "no desktop file installed"
  fi

  if [ -n "$icon" ]; then
    icon_name="$(basename "$icon")"
    cp "$icon" "$APPDIR/$icon_name"

    case "$icon" in
      *.png)
        png="$icon_name"
        ;;
      *)
        # appimagetool wants a PNG .DirIcon; SVG is only a warning today but
        # will become a hard error.
        png="org.gnome.gitlab.somas.Apostrophe.png"
        if command -v rsvg-convert >/dev/null 2>&1; then
          rsvg-convert -w 256 -h 256 "$icon" -o "$APPDIR/$png"
        elif command -v convert >/dev/null 2>&1; then
          convert -background none "$icon" -resize 256x256 "$APPDIR/$png"
        else
          warn "no SVG-to-PNG converter; .DirIcon will be SVG"
          png="$icon_name"
        fi
        ;;
    esac
    ln -sfn "$png" "$APPDIR/.DirIcon"
  else
    warn "application icon not found"
  fi

  install -Dm755 "$PACKAGING/AppRun" "$APPDIR/AppRun"
}

fetch_appimagetool() {
  local tool="$TOOLS/appimagetool-x86_64.AppImage"
  if [ ! -s "$tool" ]; then
    log "Downloading appimagetool" >&2
    curl -fL --retry 3 -o "$tool" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$tool"
  fi
  printf '%s\n' "$tool"
}

make_appimage() {
  log "Building AppImage"
  local version tool outfile comp
  local -a squashfs_args runtime_args
  version="$(grep -m1 -E "^[[:space:]]*version[[:space:]]*:" "$SRC/meson.build" \
    | sed -E "s/.*version[[:space:]]*:[[:space:]]*'([^']+)'.*/\1/")"
  [ -n "$version" ] || version="unknown"
  tool="$(fetch_appimagetool)"
  outfile="$OUT/Apostrophe-${version}-${NAME}-x86_64.AppImage"

  runtime_args=()
  if [ -s "$TOOLS/runtime-x86_64" ]; then
    runtime_args+=(--runtime-file "$TOOLS/runtime-x86_64")
  else
    warn "no cached AppImage runtime; appimagetool will try to download it"
  fi

  # The appimagetool binary bundles a minimal mksquashfs that only supports
  # zstd.  Level 19 is a little smaller than the default 15 at an acceptable
  # build-time cost.
  comp="${APPIMAGE_COMPRESS:-zstd}"
  squashfs_args=()
  if [ "$comp" = "zstd" ]; then
    squashfs_args+=(--comp zstd
      --mksquashfs-opt=-Xcompression-level
      --mksquashfs-opt="${APPIMAGE_COMPRESS_LEVEL:-19}")
  else
    squashfs_args+=(--comp "$comp")
  fi

  rm -f "$outfile"
  ARCH=x86_64 "$tool" "${runtime_args[@]}" "${squashfs_args[@]}" \
    "$APPDIR" "$outfile"
  chmod +x "$outfile"
  echo "$outfile"
}

build_app
install_revealjs
bundle_python
patch_paths
bundle_data
bundle_webkit
bundle_tools
bundle_elf
install_metadata
make_appimage

log "Build complete"
