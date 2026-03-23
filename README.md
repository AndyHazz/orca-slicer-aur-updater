# orca-slicer-aur-updater

Automated updater for the [`orca-slicer-unstable-bin`](https://aur.archlinux.org/packages/orca-slicer-unstable-bin) AUR package.

Polls the [OrcaSlicer GitHub releases](https://github.com/OrcaSlicer/OrcaSlicer/releases) every 10 minutes and pushes version bumps to AUR when a new release is found (stable, RC, or beta — excluding nightly builds).

## How it works

1. Checks the GitHub releases API for the latest versioned release (`v*`)
2. Compares against a local state file (`~/.orca-aur-last-version`)
3. If new: downloads the AppImage, computes sha512, checks for dependency changes, updates PKGBUILD + .SRCINFO, commits, and pushes to AUR

### Version scheme

Hyphens are stripped from version strings so that `vercmp` sorts correctly:

- `2.3.3-beta1` → `2.3.3beta1`
- `2.3.3-rc1` → `2.3.3rc1`
- `2.3.3` → `2.3.3` (stable, bare)

This ensures `beta < rc < stable` ordering — alphabetic segments sort below "nothing" in pacman's `vercmp`.

### Dependency detection

On each update, the script automatically checks for new dependencies using two methods:

1. **ELF DT_NEEDED parsing** — extracts the main binary from the AppImage's squashfs and parses the ELF headers to find directly linked shared libraries. Runs on ARM (no `ldd` required) using pure Python struct parsing.

2. **Upstream dep tracking** — diffs the upstream [`scripts/linux.d/arch`](https://github.com/OrcaSlicer/OrcaSlicer/blob/main/scripts/linux.d/arch) file between releases to catch non-library dependencies (fonts, plugins, etc.) that wouldn't appear in ELF headers.

New dependencies are automatically added to the PKGBUILD `depends` array and `.SRCINFO`.

## Setup

### Prerequisites

- `curl`, `jq`, `git`, `sha512sum`, `python3`, `unsquashfs` (from `squashfs-tools`)
- SSH key registered with [AUR](https://aur.archlinux.org/)

### Install

```bash
git clone https://github.com/AndyHazz/orca-slicer-aur-updater.git
cd orca-slicer-aur-updater

# Copy the systemd units
mkdir -p ~/.config/systemd/user
cp orca-aur-updater.{service,timer} ~/.config/systemd/user/

# Copy the script
cp update-orca-aur.sh ~/update-orca-aur.sh
chmod +x ~/update-orca-aur.sh

# Enable the timer
loginctl enable-linger $USER
systemctl --user daemon-reload
systemctl --user enable --now orca-aur-updater.timer
```

### Manual run

```bash
~/update-orca-aur.sh
```

## Configuration

Edit `update-orca-aur.sh` to change:

- `REPO_DIR` — where the AUR git repo is cloned
- `STATE_FILE` — path to the version state file

Edit `orca-aur-updater.timer` to change the check frequency (default: every 10 minutes).

## State files

The script maintains these state files in `$HOME`:

| File | Purpose |
|------|---------|
| `.orca-aur-last-version` | Last pushed version (prevents duplicate pushes) |
| `.orca-aur-elf-deps` | ELF DT_NEEDED entries from last version (baseline for diff) |
| `.orca-aur-last-deps` | Upstream `scripts/linux.d/arch` packages from last version |
