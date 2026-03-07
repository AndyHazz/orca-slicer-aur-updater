#!/usr/bin/env bash
set -euo pipefail

# Automated AUR updater for orca-slicer-unstable-bin
# Checks GitHub for new OrcaSlicer pre-releases and pushes to AUR

REPO_DIR="$HOME/orca-slicer-unstable-bin"
STATE_FILE="$HOME/.orca-aur-last-version"
AUR_REMOTE="ssh://aur@aur.archlinux.org/orca-slicer-unstable-bin.git"
GITHUB_API="https://api.github.com/repos/OrcaSlicer/OrcaSlicer/releases"
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

# AUR version format: hyphens become underscores
PKGVER="${VERSION//-/_}"

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

# Clone or update AUR repo
if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" pull --ff-only
else
    git clone "$AUR_REMOTE" "$REPO_DIR"
fi

# Update PKGBUILD
cd "$REPO_DIR"
sed -i "s/^pkgver=.*/pkgver=$PKGVER/" PKGBUILD
sed -i "s/^_pkgver=.*/_pkgver=$VERSION/" PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
sed -i "s/^sha512sums=.*/sha512sums=('$SHA512')/" PKGBUILD

# Regenerate .SRCINFO by parsing PKGBUILD
# Extract values from PKGBUILD
_pkgdesc=$(sed -n 's/^pkgdesc="\(.*\)"/\1/p' PKGBUILD)
_url=$(sed -n 's/^url="\(.*\)"/\1/p' PKGBUILD)
_license=$(sed -n "s/^license=('\(.*\)')/\1/p" PKGBUILD)
_source="https://github.com/OrcaSlicer/OrcaSlicer/releases/download/v${VERSION}/${APPIMAGE}"
_sha512="$SHA512"

# Extract depends array
_depends=$(sed -n "s/^depends=(\(.*\))/\1/p" PKGBUILD | tr -d "'" | tr ' ' '\n')

# Extract options array
_options=$(sed -n "s/^options=(\(.*\))/\1/p" PKGBUILD | tr -d "'" | tr ' ' '\n')

cat > .SRCINFO <<SRCINFO
pkgbase = orca-slicer-unstable-bin
	pkgdesc = $_pkgdesc
	pkgver = $PKGVER
	pkgrel = 1
	url = $_url
	arch = x86_64
	license = $_license
$(echo "$_depends" | while read -r d; do [[ -n "$d" ]] && echo "	depends = $d"; done)
	provides = orca-slicer
	conflicts = orca-slicer
$(echo "$_options" | while read -r o; do [[ -n "$o" ]] && echo "	options = $o"; done)
	source = $_source
	sha512sums = $_sha512

pkgname = orca-slicer-unstable-bin
SRCINFO

# Commit and push
git add PKGBUILD .SRCINFO
git -c user.name="AndyHazz" -c user.email="517731+AndyHazz@users.noreply.github.com" \
    commit -m "orca-slicer-unstable-bin: bump pkgver to $VERSION"
git push

# Record version
echo "$VERSION" > "$STATE_FILE"
log "Successfully updated AUR to $VERSION"
