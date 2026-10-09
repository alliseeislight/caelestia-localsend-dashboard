#!/usr/bin/env bash
#
# Caelestia × LocalSend dashboard widget — uninstaller
#
# Removes the receiver service, the Quickshell widget and restores the
# Content.qml backup created by install.sh. Use --purge to also delete the
# localgo binary and the receiver's cached data.
#
set -euo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
QS_CONFIG="$CONFIG_HOME/quickshell/caelestia"
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
