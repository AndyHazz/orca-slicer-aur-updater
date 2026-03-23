#!/usr/bin/env bash
set -euo pipefail

# Automated AUR updater for orca-slicer-unstable-bin
# Checks GitHub for new OrcaSlicer releases and pushes to AUR
# Includes dependency detection via ELF parsing and upstream arch dep tracking

REPO_DIR="$HOME/orca-slicer-unstable-bin"
STATE_FILE="$HOME/.orca-aur-last-version"
DEPS_STATE_FILE="$HOME/.orca-aur-last-deps"
AUR_REMOTE="ssh://aur@aur.archlinux.org/orca-slicer-unstable-bin.git"
GITHUB_API="https://api.github.com/repos/OrcaSlicer/OrcaSlicer/releases"
GITHUB_RAW="https://raw.githubusercontent.com/OrcaSlicer/OrcaSlicer"
LOG_TAG="orca-aur-updater"

log() { logger -t "$LOG_TAG" "$*"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Fetch latest release (stable, RC, beta — excluding nightly-builds)
LATEST=$(curl -sL "$GITHUB_API?per_page=10" \
    | jq -r '[.[] | select(.tag_name | test("^v[0-9]"))][0].tag_name // empty')

if [[ -z "$LATEST" ]]; then
    log "ERROR: Could not fetch latest release from GitHub"
    exit 1
fi

# Strip leading 'v'
VERSION="${LATEST#v}"
log "Latest release: $VERSION"

# Check against last-pushed version
LAST_VERSION=""
[[ -f "$STATE_FILE" ]] && LAST_VERSION=$(cat "$STATE_FILE")

if [[ "$VERSION" == "$LAST_VERSION" ]]; then
    log "Already up to date ($VERSION)"
    exit 0
fi

log "New version found: $VERSION (was: ${LAST_VERSION:-none})"

# AUR version: strip hyphens so vercmp sorts correctly (beta < rc < stable)
# e.g. 2.3.3-rc1 → 2.3.3rc1 (sorts below 2.3.3)
PKGVER="${VERSION//-/}"

# Download AppImage and compute checksum
APPIMAGE="OrcaSlicer_Linux_AppImage_Ubuntu2404_V${VERSION}.AppImage"
DOWNLOAD_URL="https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v${VERSION}/${APPIMAGE}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

log "Downloading $APPIMAGE..."
if ! curl -fSL -o "$TMPDIR/$APPIMAGE" "$DOWNLOAD_URL"; then
    log "ERROR: Download failed for $DOWNLOAD_URL"
    exit 1
fi

SHA512=$(sha512sum "$TMPDIR/$APPIMAGE" | awk '{print $1}')
log "SHA512: $SHA512"

# --- Dependency detection ---
# Checks for new dependencies by:
# 1. Parsing ELF DT_NEEDED entries from the AppImage binary (catches .so deps)
# 2. Diffing upstream scripts/linux.d/arch (catches non-.so deps like fonts)

check_dependencies() {
    local appimage="$1"
    local version="$2"
    local repo_dir="$3"
    local new_deps=()

    # Get current PKGBUILD depends
    local current_deps
    current_deps=$(sed -n "s/^depends=(\(.*\))/\1/p" "$repo_dir/PKGBUILD" | tr -d "'")

    # --- Check 1: ELF DT_NEEDED analysis ---
    log "Checking ELF dependencies..."

    # Find squashfs offset (look for hsqs magic with valid v4 header)
    local sqfs_offset
    sqfs_offset=$(python3 -c "
import struct
with open('$appimage', 'rb') as f:
    data = f.read()
    pos = 0
    while True:
        pos = data.find(b'hsqs', pos)
        if pos == -1:
            break
        # Check squashfs version (bytes 28-29) — v4 is current
        ver = struct.unpack_from('<H', data, pos + 28)[0]
        if ver == 4:
            print(pos)
            break
        pos += 1
")

    if [[ -n "$sqfs_offset" ]]; then
        # Extract squashfs from AppImage
        python3 -c "
with open('$appimage', 'rb') as fin, open('$TMPDIR/app.squashfs', 'wb') as fout:
    fin.seek($sqfs_offset)
    while chunk := fin.read(1048576):
        fout.write(chunk)
"
        # Extract just the main binary
        if unsquashfs -f -d "$TMPDIR/extracted" "$TMPDIR/app.squashfs" bin/orca-slicer >/dev/null 2>&1; then
            # Parse ELF DT_NEEDED entries (architecture-independent)
            local elf_libs
            elf_libs=$(python3 -c "
import struct

with open('$TMPDIR/extracted/bin/orca-slicer', 'rb') as f:
    ident = f.read(16)
    assert ident[:4] == b'\x7fELF', 'Not an ELF file'

    f.seek(0)
    hdr = f.read(64)
    e_phoff = struct.unpack_from('<Q', hdr, 32)[0]
    e_phentsize = struct.unpack_from('<H', hdr, 54)[0]
    e_phnum = struct.unpack_from('<H', hdr, 56)[0]

    dyn_offset = dyn_size = 0
    load_segments = []
    for i in range(e_phnum):
        f.seek(e_phoff + i * e_phentsize)
        phdr = f.read(e_phentsize)
        p_type = struct.unpack_from('<I', phdr, 0)[0]
        p_offset = struct.unpack_from('<Q', phdr, 8)[0]
        p_vaddr = struct.unpack_from('<Q', phdr, 16)[0]
        p_filesz = struct.unpack_from('<Q', phdr, 32)[0]
        if p_type == 1: load_segments.append((p_vaddr, p_offset, p_filesz))
        if p_type == 2: dyn_offset, dyn_size = p_offset, p_filesz

    needed_offsets = []
    strtab_vaddr = 0
    f.seek(dyn_offset)
    while True:
        d_tag, d_val = struct.unpack('<qQ', f.read(16))
        if d_tag == 0: break
        if d_tag == 1: needed_offsets.append(d_val)
        if d_tag == 5: strtab_vaddr = d_val

    strtab_foff = 0
    for vaddr, foff, fsz in load_segments:
        if vaddr <= strtab_vaddr < vaddr + fsz:
            strtab_foff = foff + (strtab_vaddr - vaddr)
            break

    for off in needed_offsets:
        f.seek(strtab_foff + off)
        name = b''
        while (c := f.read(1)) != b'\x00' and c: name += c
        print(name.decode())
" 2>/dev/null)

            if [[ -n "$elf_libs" ]]; then
                # Save current ELF deps for comparison
                local elf_deps_file="$HOME/.orca-aur-elf-deps"
                local prev_elf_deps=""
                [[ -f "$elf_deps_file" ]] && prev_elf_deps=$(cat "$elf_deps_file")

                echo "$elf_libs" > "$elf_deps_file"

                # Find new .so deps not in previous version
                if [[ -n "$prev_elf_deps" ]]; then
                    local new_libs
                    new_libs=$(comm -23 <(echo "$elf_libs" | sort) <(echo "$prev_elf_deps" | sort))
                    if [[ -n "$new_libs" ]]; then
                        log "New ELF dependencies detected: $new_libs"
                        # Map .so names to Arch package names using Ubuntu→Arch common mappings
                        # (Can't use pacman on ARM Pi, so use a known mapping table)
                        while read -r lib; do
                            local pkg
                            pkg=$(map_lib_to_package "$lib")
                            if [[ -n "$pkg" ]] && ! echo "$current_deps" | grep -qw "$pkg"; then
                                new_deps+=("$pkg")
                                log "New dependency needed: $pkg (provides $lib)"
                            fi
                        done <<< "$new_libs"
                    fi
                fi
            fi

            rm -rf "$TMPDIR/extracted"
        else
            log "WARNING: Failed to extract binary from squashfs"
        fi
        rm -f "$TMPDIR/app.squashfs"
    else
        log "WARNING: Could not find squashfs offset in AppImage"
    fi

    # --- Check 2: Upstream scripts/linux.d/arch diff ---
    log "Checking upstream Arch dependency list..."
    local upstream_deps
    upstream_deps=$(curl -sL "$GITHUB_RAW/v${version}/scripts/linux.d/arch" 2>/dev/null \
        | sed -n '/REQUIRED_DEV_PACKAGES=(/,/)/p' \
        | grep -oP "^\s+\K\S+" | sort)

    if [[ -n "$upstream_deps" ]]; then
        if [[ -f "$DEPS_STATE_FILE" ]]; then
            local new_upstream
            new_upstream=$(comm -23 <(echo "$upstream_deps") <(cat "$DEPS_STATE_FILE"))
            if [[ -n "$new_upstream" ]]; then
                log "New upstream Arch dependencies: $new_upstream"
                while read -r pkg; do
                    [[ -z "$pkg" ]] && continue
                    # Map upstream package names to runtime equivalents
                    local mapped
                    mapped=$(map_upstream_to_runtime "$pkg")
                    if [[ -n "$mapped" ]] && ! echo "$current_deps" | grep -qw "$mapped"; then
                        new_deps+=("$mapped")
                        log "New upstream dependency: $mapped (from $pkg)"
                    fi
                done <<< "$new_upstream"
            fi
        fi
        echo "$upstream_deps" > "$DEPS_STATE_FILE"
    fi

    # --- Apply new dependencies ---
    if [[ ${#new_deps[@]} -gt 0 ]]; then
        # Deduplicate
        local unique_deps
        unique_deps=$(printf '%s\n' "${new_deps[@]}" | sort -u)

        log "Adding new dependencies to PKGBUILD: $unique_deps"
        while read -r dep; do
            [[ -z "$dep" ]] && continue
            # Add to PKGBUILD depends array
            sed -i "s/^depends=(\(.*\))/depends=(\1 '$dep')/" "$repo_dir/PKGBUILD"
            # Add to .SRCINFO before provides line
            sed -i "/\tprovides = /i\\\\tdepends = $dep" "$repo_dir/.SRCINFO"
            log "Added dependency: $dep"
        done <<< "$unique_deps"
    else
        log "No new dependencies detected"
    fi
}

# Map common .so names to Arch package names
# This covers libraries that OrcaSlicer is known to link against
map_lib_to_package() {
    local lib="$1"
    case "$lib" in
        libmspack.so*)     echo "libmspack" ;;
        libGLU.so*)        echo "glu" ;;
        libcairo*.so*)     echo "cairo" ;;
        libgtk-3.so*)      echo "gtk3" ;;
        libgdk-3.so*)      echo "gtk3" ;;
        libwebkit2gtk-4.1.so*) echo "webkit2gtk-4.1" ;;
        libgstreamer-1.0.so*) echo "gstreamer" ;;
        libgst*.so*)       echo "gst-plugins-base" ;;
        libwayland*.so*)   echo "wayland" ;;
        libEGL.so*|libGL.so*|libGLX.so*|libOpenGL.so*) echo "" ;; # libglvnd, transitive
        libsecret*.so*)    echo "" ;; # transitive via webkit2gtk
        libsoup*.so*)      echo "" ;; # transitive via webkit2gtk
        lib[Xx]*.so*)      echo "" ;; # X11 libs, transitive
        libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*) echo "" ;; # glibc
        libgcc_s.so*|libstdc++.so*) echo "" ;; # gcc runtime
        libglib-2.0.so*|libgobject-2.0.so*|libgio-2.0.so*) echo "" ;; # transitive
        libpango*.so*)     echo "" ;; # transitive via gtk3
        libharfbuzz*.so*)  echo "" ;; # transitive via pango
        libfontconfig*.so*) echo "" ;; # transitive
        libatk*.so*)       echo "" ;; # transitive via gtk3
        libgdk_pixbuf*.so*) echo "" ;; # transitive via gtk3
        libdbus*.so*)      echo "" ;; # transitive
        libz.so*)          echo "" ;; # zlib, transitive
        *)                 echo "$lib" ;; # unknown — return as-is for logging
    esac
}

# Map upstream build dep names to runtime package names
map_upstream_to_runtime() {
    local pkg="$1"
    # Skip build-only tools
    case "$pkg" in
        cmake|ninja|git|wget|curl|file|gettext|texinfo|extra-cmake-modules|lld|clang) echo "" ;;
        # Map upstream names to runtime equivalents
        webkit2gtk)        echo "webkit2gtk-4.1" ;;
        gstreamermm)       echo "" ;; # C++ bindings, build-only
        eglexternalplatform) echo "" ;; # dev headers only
        mesa|openssl|dbus) echo "" ;; # transitive deps
        glew|libspnav)     echo "" ;; # not linked at runtime (statically linked or optional)
        *)                 echo "$pkg" ;;
    esac
}

# --- Main flow ---

# Clone or update AUR repo
if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" pull --ff-only
else
    git clone "$AUR_REMOTE" "$REPO_DIR"
fi

# Check for dependency changes (uses the downloaded AppImage)
check_dependencies "$TMPDIR/$APPIMAGE" "$VERSION" "$REPO_DIR"

# Update PKGBUILD version and checksum
cd "$REPO_DIR"
sed -i "s/^pkgver=.*/pkgver=$PKGVER/" PKGBUILD
sed -i "s/^_pkgver=.*/_pkgver=$VERSION/" PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
sed -i "s/^sha512sums=.*/sha512sums=('$SHA512')/" PKGBUILD

# Update .SRCINFO in-place
_source="https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v${VERSION}/${APPIMAGE}"
sed -i "s/\tpkgver = .*/\tpkgver = $PKGVER/" .SRCINFO
sed -i "s/\tpkgrel = .*/\tpkgrel = 1/" .SRCINFO
sed -i "s|\tsource = .*|\tsource = $_source|" .SRCINFO
sed -i "s/\tsha512sums = .*/\tsha512sums = $SHA512/" .SRCINFO

# Commit and push
git add PKGBUILD .SRCINFO
git -c user.name="AndyHazz" -c user.email="517731+AndyHazz@users.noreply.github.com" \
    commit -m "orca-slicer-unstable-bin: bump to $VERSION"
git push

# Record version
echo "$VERSION" > "$STATE_FILE"
log "Successfully updated AUR to $VERSION"
