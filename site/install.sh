#!/bin/bash
# Racky installer: curl -fsSL https://github.com/gabrielgreco1/racky/releases/latest/download/install.sh | bash
# Downloads the latest Racky.dmg from GitHub Releases, checks its sha256, installs Racky.app into /Applications and opens it.
# Downloaded with curl, the app carries no quarantine flag, so macOS opens it without the "can't verify the developer" prompt.
set -euo pipefail

REPO="gabrielgreco1/racky"
BASE="https://github.com/$REPO/releases/latest/download"
DEST="${RACKY_INSTALL_DIR:-/Applications}"
APP="$DEST/Racky.app"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Racky runs on macOS."
[ "$(uname -m)" = "arm64" ] || fail "Racky needs a Mac with Apple silicon."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 26 ] || fail "Racky needs macOS 26 or later (this Mac has $(sw_vers -productVersion))."

TMP="$(mktemp -d)"
MNT=""
cleanup() { [ -n "$MNT" ] && hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

bold "Downloading Racky…"
curl -fL --progress-bar -o "$TMP/Racky.dmg" "$BASE/Racky.dmg"
curl -fsSL -o "$TMP/Racky.dmg.sha256" "$BASE/Racky.dmg.sha256"
EXPECTED="$(awk '{print $1}' "$TMP/Racky.dmg.sha256")"
ACTUAL="$(shasum -a 256 "$TMP/Racky.dmg" | awk '{print $1}')"
[ "$EXPECTED" = "$ACTUAL" ] || fail "download is corrupted (sha256 mismatch). Try again."

MNT="$TMP/mnt"
mkdir -p "$MNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$TMP/Racky.dmg" || fail "could not open Racky.dmg."
[ -d "$MNT/Racky.app" ] || fail "Racky.app not found in the download."

# Only the copy being replaced is closed; a Racky running from elsewhere is left alone.
RUNNING="${APP}/Contents/MacOS/Racky"
if pgrep -qf "$RUNNING"; then
  bold "Closing Racky to update it (your agents keep running)…"
  osascript -e "tell application \"${APP}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -qf "$RUNNING" || break; sleep 1; done
  pgrep -qf "$RUNNING" && fail "Racky is still open. Quit it and run the installer again."
fi

bold "Installing to ${DEST}…"
mkdir -p "$DEST"
if [ -w "$DEST" ]; then
  rm -rf "$APP"; ditto "$MNT/Racky.app" "$APP"
else
  sudo rm -rf "$APP"; sudo ditto "$MNT/Racky.app" "$APP"
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if [ "${RACKY_INSTALL_NO_OPEN:-0}" != "1" ]; then
  open "$APP"
fi
bold "Racky is installed. Enjoy!"
