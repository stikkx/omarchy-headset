#!/usr/bin/env bash
# Optional extras for the stikkx.headset Omarchy plugin.
#
# The plugin itself installs with:
#   omarchy plugin add https://github.com/stikkx/omarchy-headset --enable
#
# This script adds what a plugin cannot do on its own, only when asked:
#   ./install.sh               link the `headsetctl` CLI into ~/.local/bin
#   ./install.sh --hotkey      ...and add Super+Shift+H / Super+Ctrl+Shift+H
#                              to ~/.config/hypr/bindings.lua (backed up first)
#   ./install.sh --uninstall   remove the CLI link and the hotkey block
#
# Run from a source checkout (outside ~/.config/omarchy/plugins) it also
# copies the plugin files into place, for local development.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ID="stikkx.headset"
DEST="$HOME/.config/omarchy/plugins/$ID"
BINDINGS="$HOME/.config/hypr/bindings.lua"
BEGIN="-- >>> $ID hotkeys"
END="-- <<< $ID hotkeys"

remove_hotkeys() { # [--no-backup]
  [[ -f "$BINDINGS" ]] && grep -qF -- "$BEGIN" "$BINDINGS" || return 0
  [[ "${1:-}" == --no-backup ]] || cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
  sed -i "\|^$BEGIN\$|,\|^$END\$|d" "$BINDINGS"
  hyprctl reload >/dev/null 2>&1 || true
  echo "✓ hotkeys removed (backup next to $BINDINGS)"
}

if [[ "${1:-}" == "--uninstall" ]]; then
  remove_hotkeys
  [[ -L "$HOME/.local/bin/headsetctl" ]] && rm "$HOME/.local/bin/headsetctl" && echo "✓ removed ~/.local/bin/headsetctl"
  echo "To remove the plugin itself: omarchy plugin remove $ID"
  exit 0
fi

for dep in pactl jq bluetoothctl wpctl; do
  command -v "$dep" >/dev/null || { echo "missing dependency: $dep" >&2; exit 1; }
done

# Dev mode: deploy a source checkout. The shell's QML scanner rejects
# symlinked plugin dirs, so copy.
if [[ "$SRC" != "$DEST" ]]; then
  mkdir -p "$DEST/bin"
  install -m644 "$SRC"/{manifest.json,Panel.qml,Model.js,README.md,LICENSE} "$DEST/"
  install -m755 "$SRC/bin/headsetctl" "$DEST/bin/headsetctl"
  echo "✓ plugin files copied to $DEST"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  grep -q "\"$ID\"" "$HOME/.config/omarchy/shell.json" 2>/dev/null \
    || omarchy bar put "$ID" --after omarchy.bluetooth >/dev/null 2>&1 \
    || omarchy bar put "$ID"
fi

mkdir -p "$HOME/.local/bin"
ln -sfn "$DEST/bin/headsetctl" "$HOME/.local/bin/headsetctl"
echo "✓ CLI linked: ~/.local/bin/headsetctl"

if [[ "${1:-}" == "--hotkey" && -f "$BINDINGS" ]]; then
  cp "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
  remove_hotkeys --no-backup >/dev/null
  cat >>"$BINDINGS" <<EOF

$BEGIN
o.bind("SUPER + SHIFT + H", "Headset mode", "$DEST/bin/headsetctl toggle")
o.bind("SUPER + CTRL + SHIFT + H", "Headset panel", "omarchy-shell $ID toggle")
$END
EOF
  hyprctl reload >/dev/null
  errs=$(hyprctl configerrors)
  [[ -n "$errs" && "$errs" != *"no errors"* ]] && echo "! hyprctl configerrors: $errs"
  echo "✓ hotkeys: Super+Shift+H (mode), Super+Ctrl+Shift+H (panel)"
fi

command -v headsetcontrol >/dev/null \
  || echo "→ For USB headsets (Arctis 7…): headsetctl setup usb  (or the button in the panel)"
