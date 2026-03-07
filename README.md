# orca-slicer-aur-updater

Automated updater for the [`orca-slicer-unstable-bin`](https://aur.archlinux.org/packages/orca-slicer-unstable-bin) AUR package.

Polls the [OrcaSlicer GitHub releases](https://github.com/OrcaSlicer/OrcaSlicer/releases) hourly and pushes version bumps to AUR when a new release is found (stable, RC, or beta — excluding nightly builds).

## How it works

1. Checks the GitHub releases API for the latest versioned release (`v*`)
2. Compares against a local state file (`~/.orca-aur-last-version`)
3. If new: downloads the AppImage, computes sha512, updates PKGBUILD + .SRCINFO, commits, and pushes to AUR

## Setup

### Prerequisites

- `curl`, `jq`, `git`, `sha512sum`
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

Edit `orca-aur-updater.timer` to change the check frequency (default: hourly).
