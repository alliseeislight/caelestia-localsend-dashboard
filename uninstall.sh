#!/usr/bin/env bash
#
# Caelestia × LocalSend dashboard widget — uninstaller
#
# Removes the receiver service, the Quickshell widget and restores the
# Content.qml backup created by install.sh. Use --purge to also delete the
# localgo binary and the receiver's cached data.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
USER_CAELESTIA="$CONFIG_HOME/quickshell/caelestia"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_USER_DIR="$CONFIG_HOME/systemd/user"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/localgo"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/localgo"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; Z=$'\033[0m'
else
    B=""; G=""; Y=""; C=""; Z=""
fi
info() { printf '%s\n' "${C}==>${Z} ${B}$*${Z}"; }
ok()   { printf '%s\n' "${G}  ✓${Z} $*"; }
warn() { printf '%s\n' "${Y}  !${Z} $*"; }

# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# The installer always wires the widget into the per-user copy of the shell.
# If it isn't there, look for it wherever it was installed (e.g. an older or
# manual install), but never edit root-owned system files without permission.
QS_CONFIG="$USER_CAELESTIA"
if [ ! -f "$QS_CONFIG/services/LocalSend.qml" ] && [ ! -f "$QS_CONFIG/modules/dashboard/LocalSendTab.qml" ]; then
    if FOUND="$(caelestia_with_widget)"; then
        if [ -w "$FOUND" ]; then
            QS_CONFIG="$FOUND"
        else
            warn "The widget appears to be installed system-wide at $FOUND."
            warn "Re-run this script with sudo to remove it there; skipping those files."
        fi
    fi
fi

# ── 1. receiver service ─────────────────────────────────────────────────────
info "Removing the receiver service"
if systemctl --user list-unit-files localgo.service >/dev/null 2>&1; then
    systemctl --user disable --now localgo.service >/dev/null 2>&1 || true
    ok "Disabled and stopped localgo.service"
fi
if [ -f "$SYSTEMD_USER_DIR/localgo.service" ]; then
    rm -f "$SYSTEMD_USER_DIR/localgo.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ok "Removed $SYSTEMD_USER_DIR/localgo.service"
fi

# ── 2. Quickshell widget ────────────────────────────────────────────────────
info "Removing the Quickshell widget"
for rel in "services/LocalSend.qml" "modules/dashboard/LocalSendTab.qml"; do
    target="$QS_CONFIG/$rel"
    if [ -f "$target" ]; then
        latest="$(ls -1t "$target".bak.* 2>/dev/null | head -n1 || true)"
        if [ -n "$latest" ]; then
            mv -f "$latest" "$target"
            ok "Restored $rel from $(basename "$latest")"
        else
            rm -f "$target"
            ok "Removed $rel"
        fi
    fi
done

# ── 3. un-patch Content.qml ─────────────────────────────────────────────────
info "Restoring Content.qml"
CONTENT="$QS_CONFIG/modules/dashboard/Content.qml"
latest="$(ls -1t "$CONTENT".bak.* 2>/dev/null | head -n1 || true)"
if [ -n "$latest" ]; then
    cp -a "$latest" "$CONTENT"
    ok "Restored Content.qml from $(basename "$latest")"
else
    warn "No Content.qml backup found — remove the LocalSend tab by hand if needed."
fi

# ── 4. optional purge ───────────────────────────────────────────────────────
if [ "$PURGE" -eq 1 ]; then
    info "Purging the localgo binary and cached data"
    rm -f "$BIN_DIR/localgo" && ok "Removed $BIN_DIR/localgo"
    rm -rf "$CACHE_DIR" "$DATA_DIR" && ok "Removed $CACHE_DIR and $DATA_DIR"
fi

# ── 5. reload the shell ─────────────────────────────────────────────────────
info "Reloading the Caelestia shell"
if command -v qs >/dev/null 2>&1; then
    qs -c caelestia kill >/dev/null 2>&1 || true
    sleep 0.2
    qs -c caelestia -d >/dev/null 2>&1 || true
    ok "Shell reloaded"
elif command -v caelestia >/dev/null 2>&1; then
    caelestia shell -r >/dev/null 2>&1 || true
    ok "Shell restarted"
fi

printf '\n%s\n' "${G}${B}Uninstalled.${Z}"
[ "$PURGE" -eq 1 ] || printf '%s\n' "  (run with ${B}--purge${Z} to also delete the localgo binary and its cached data)"
if [ -f "$USER_CAELESTIA/.caelestia-localsend-copy" ]; then
    printf '\n%s\n' "  Note: a personal copy of the shell remains at $USER_CAELESTIA."
    printf '%s\n' "  It was created so the tab could be added without root, and now shadows"
    printf '%s\n' "  the packaged shell. Delete that folder to fall back to the packaged copy."
fi
