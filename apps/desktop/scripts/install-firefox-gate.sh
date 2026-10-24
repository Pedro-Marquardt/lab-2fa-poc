#!/usr/bin/env bash
# User-level Firefox .desktop override → bioentropy-gate (no root).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/scripts/bioentropy-gate"
DEST_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DEST="$DEST_DIR/firefox.desktop"
FIREFOX_BIN="$(command -v firefox || true)"

if [[ -z "$FIREFOX_BIN" ]]; then
  echo "firefox not found in PATH" >&2
  exit 1
fi

chmod +x "$GATE"
mkdir -p "$DEST_DIR"

# Prefer copying system desktop file if present, then rewrite Exec.
SRC=""
for c in \
  /usr/share/applications/firefox.desktop \
  /usr/share/applications/org.mozilla.firefox.desktop \
  /var/lib/flatpak/exports/share/applications/org.mozilla.firefox.desktop
do
  if [[ -f "$c" ]]; then
    SRC="$c"
    break
  fi
done

if [[ -n "$SRC" ]]; then
  cp "$SRC" "$DEST"
  # Replace Exec= lines that launch firefox with the gate.
  # Keep %u / %U placeholders when present.
  python3 - <<'PY' "$DEST" "$GATE" "$FIREFOX_BIN"
import re, sys
dest, gate, firefox = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(dest, encoding="utf-8").read().splitlines(True)
out = []
for line in text:
    if line.startswith("Exec="):
        rest = line[len("Exec="):].rstrip("\n")
        # Preserve trailing field codes (%u etc.)
        m = re.search(r"(\s+%[a-zA-Z])+\s*$", rest)
        suffix = m.group(0) if m else ""
        out.append(f"Exec={gate} --app browser -- {firefox}{suffix}\n")
    else:
        out.append(line)
open(dest, "w", encoding="utf-8").writelines(out)
PY
else
  cat >"$DEST" <<EOF
[Desktop Entry]
Version=1.0
Name=Firefox Web Browser
Comment=Browse the Web (Bioentropy Lab 2FA gate)
Exec=$GATE --app browser -- $FIREFOX_BIN %u
Icon=firefox
Terminal=false
Type=Application
Categories=Network;WebBrowser;
StartupNotify=true
EOF
fi

update-desktop-database "$DEST_DIR" 2>/dev/null || true
echo "Installed: $DEST"
echo "Exec uses: $GATE --app browser -- $FIREFOX_BIN"
echo "With Lab 2FA running, dock/menu Firefox goes through presence challenge."
echo "With Lab 2FA stopped, gate passthroughs to real Firefox."
