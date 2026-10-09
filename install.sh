#!/usr/bin/env bash
#
# Caelestia × LocalSend dashboard widget — installer
# https://github.com/alliseeislight/caelestia-localsend-dashboard
#
# Installs the headless `localgo` receiver, wires the LocalSend tab into the
# Caelestia dashboard, and (re)starts the shell. Safe to re-run.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
# Resolved by the preflight below (Caelestia may be installed system-wide).
QS_CONFIG="$CONFIG_HOME/quickshell/caelestia"
BIN_DIR="$HOME/.local/bin"
SYSTEMD_USER_DIR="$CONFIG_HOME/systemd/user"
STAMP="$(date +%Y%m%d-%H%M%S)"

LOCALGO_VERSION="0.6.7"
LOCALGO_REPO="bethropolis/localgo"

# ── pretty output ───────────────────────────────────────────────────────────
if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; Z=$'\033[0m'
else
    B=""; G=""; Y=""; R=""; C=""; Z=""
fi
info() { printf '%s\n' "${C}==>${Z} ${B}$*${Z}"; }
ok()   { printf '%s\n' "${G}  ✓${Z} $*"; }
warn() { printf '%s\n' "${Y}  !${Z} $*"; }
die()  { printf '%s\n' "${R}  ✗${Z} $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ── 1. preflight ────────────────────────────────────────────────────────────
info "Preflight checks"

# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

# Caelestia can live in a few places; find the one Quickshell will actually load.
USER_CAELESTIA="$CONFIG_HOME/quickshell/caelestia"
if ! ACTIVE_CAELESTIA="$(caelestia_active)"; then
    {
        printf '%s\n' "Caelestia shell config not found. Looked in:"
        while IFS= read -r cand; do printf '  - %s\n' "$cand"; done < <(caelestia_candidates)
    } >&2
    die "Install Caelestia first — the caelestia-shell package or a git clone of caelestia-dots/shell."
fi

# Resolve symlinks up front so we never copy, or later edit, a symlink that
# points back into a root-owned location.
QS_CONFIG="$(readlink -f "$ACTIVE_CAELESTIA" 2>/dev/null || printf '%s' "$ACTIVE_CAELESTIA")"
USER_CAELESTIA="$(readlink -f "$USER_CAELESTIA" 2>/dev/null || printf '%s' "$CONFIG_HOME/quickshell/caelestia")"

# The caelestia-shell package installs to /etc/xdg/quickshell/caelestia, which
# is root-owned, so the tab cannot be wired into it. Quickshell prefers a
# per-user copy, so make one and patch that instead of touching system files.
if [ "$QS_CONFIG" != "$USER_CAELESTIA" ] && [ ! -f "$USER_CAELESTIA/shell.qml" ]; then
    info "Found Caelestia installed outside your home: $QS_CONFIG"
    warn "That location isn't yours to modify, so a personal copy will be used."
    if [ -e "$USER_CAELESTIA" ]; then
        cp -a "$USER_CAELESTIA" "$USER_CAELESTIA.bak.$STAMP"
        ok "Backed up existing $USER_CAELESTIA → $USER_CAELESTIA.bak.$STAMP"
        rm -rf "$USER_CAELESTIA"
    fi
    info "Copying the Caelestia shell → $USER_CAELESTIA"
    mkdir -p "$(dirname "$USER_CAELESTIA")"
    if ! cp -a "$QS_CONFIG" "$USER_CAELESTIA"; then
        die "Could not copy $QS_CONFIG to $USER_CAELESTIA (check permissions and free disk space)."
    fi
    QS_CONFIG="$USER_CAELESTIA"
    : > "$USER_CAELESTIA/.caelestia-localsend-copy"
    ok "Quickshell will now use $USER_CAELESTIA"
    warn "Your personal copy will not receive caelestia-shell package updates."
    warn "Delete it and re-run the installer to fall back to the packaged copy."
fi

[ -f "$QS_CONFIG/modules/dashboard/Content.qml" ] || die "Caelestia dashboard (Content.qml) not found in $QS_CONFIG."
have systemctl || die "systemd not found (this installer uses a systemd --user service)."
have curl      || die "curl not found."
have tar       || die "tar not found."
if ! have python3 && ! have python; then
    die "python3 not found (needed to patch Content.qml safely)."
fi
PY="$(have python3 && command -v python3 || command -v python)"
have zenity || warn "zenity not found — the file/folder pickers will not open. Install it (e.g. sudo pacman -S zenity)."
ok "Environment looks good ($QS_CONFIG)"

# ── 2. localgo ──────────────────────────────────────────────────────────────
info "Installing the LocalGo backend"
if have localgo; then
    LOCALGO_BIN="$(command -v localgo)"
    ok "localgo already installed: $LOCALGO_BIN"
elif [ -x "$BIN_DIR/localgo" ]; then
    LOCALGO_BIN="$BIN_DIR/localgo"
    ok "localgo already installed: $LOCALGO_BIN"
else
    case "$(uname -m)" in
        x86_64|amd64)  asset="linux_amd64" ;;
        aarch64|arm64) asset="linux_arm64" ;;
        *) die "Unsupported CPU architecture: $(uname -m)" ;;
    esac
    base="https://github.com/${LOCALGO_REPO}/releases/download/v${LOCALGO_VERSION}"
    tarball="localgo_${LOCALGO_VERSION}_${asset}.tar.gz"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    info "Downloading $tarball"
    curl -fsSL "$base/$tarball" -o "$tmp/$tarball"
    if curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" 2>/dev/null && [ -s "$tmp/checksums.txt" ]; then
        if ( cd "$tmp" && grep -- "$tarball" checksums.txt | sha256sum -c - >/dev/null 2>&1 ); then
            ok "Checksum verified"
        else
            die "Checksum verification failed for $tarball"
        fi
    else
        warn "Could not fetch checksums.txt; skipping verification"
    fi
    tar -xzf "$tmp/$tarball" -C "$tmp"
    src_bin="$(find "$tmp" -type f -name localgo | head -n1)"
    [ -n "$src_bin" ] || die "Could not find the localgo binary inside the archive."
    mkdir -p "$BIN_DIR"
    install -m755 "$src_bin" "$BIN_DIR/localgo"
    LOCALGO_BIN="$BIN_DIR/localgo"
    ok "Installed $LOCALGO_BIN ($("$LOCALGO_BIN" --version 2>/dev/null | head -n1))"
fi

# ── 3. systemd user service ─────────────────────────────────────────────────
info "Installing the receiver service"
mkdir -p "$SYSTEMD_USER_DIR"
DOWNLOAD_DIR="$HOME/Downloads"
mkdir -p "$DOWNLOAD_DIR"
if [ -f "$SYSTEMD_USER_DIR/localgo.service" ]; then
    cp -a "$SYSTEMD_USER_DIR/localgo.service" "$SYSTEMD_USER_DIR/localgo.service.bak.$STAMP"
    ok "Backed up existing unit → localgo.service.bak.$STAMP"
fi
sed -e "s|@LOCALGO@|$LOCALGO_BIN|g" \
    -e "s|@DOWNLOAD_DIR@|$DOWNLOAD_DIR|g" \
    "$REPO_DIR/systemd/localgo.service" > "$SYSTEMD_USER_DIR/localgo.service"
systemctl --user daemon-reload
systemctl --user enable --now localgo.service
sleep 0.5
systemctl --user is-active --quiet localgo.service || {
    journalctl --user -u localgo.service -n 20 --no-pager || true
    die "localgo.service failed to start (see log above). Is port 53317 already in use?"
}
ok "localgo.service is enabled and active (socket: ${XDG_CACHE_HOME:-$HOME/.cache}/localgo/ipc.sock)"

# ── 4. Quickshell files ─────────────────────────────────────────────────────
info "Installing the Quickshell widget"
mkdir -p "$QS_CONFIG/services" "$QS_CONFIG/modules/dashboard"
for rel in "services/LocalSend.qml" "modules/dashboard/LocalSendTab.qml"; do
    if [ -f "$QS_CONFIG/$rel" ]; then
        cp -a "$QS_CONFIG/$rel" "$QS_CONFIG/$rel.bak.$STAMP"
        ok "Backed up existing $rel → $rel.bak.$STAMP"
    fi
    install -m644 "$REPO_DIR/config/$rel" "$QS_CONFIG/$rel"
done
ok "Installed LocalSend.qml and LocalSendTab.qml"

# ── 5. wire the tab into Content.qml ────────────────────────────────────────
info "Wiring the LocalSend tab into Content.qml"
CONTENT="$QS_CONFIG/modules/dashboard/Content.qml"
if grep -q "localSendComponent" "$CONTENT"; then
    ok "Content.qml already patched; nothing to do"
else
    cp -a "$CONTENT" "$CONTENT.bak.$STAMP"
    "$PY" "$REPO_DIR/scripts/patch-content.py" "$CONTENT"
    ok "Patched Content.qml (backup: Content.qml.bak.$STAMP)"
fi

# ── 6. avoid the LocalSend GUI fighting for port 53317 ──────────────────────
AUTOSTART_FILE="$CONFIG_HOME/autostart/localsend_app.desktop"
if [ -f "$AUTOSTART_FILE" ]; then
    cp -a "$AUTOSTART_FILE" "$AUTOSTART_FILE.bak.$STAMP"
    mv "$AUTOSTART_FILE" "$AUTOSTART_FILE.disabled"
    ok "Disabled the LocalSend GUI autostart (avoids port 53317 conflict)"
fi

# ── 7. reload the shell ─────────────────────────────────────────────────────
info "Reloading the Caelestia shell"
if have qs; then
    qs -c caelestia kill >/dev/null 2>&1 || true
    sleep 0.2
    qs -c caelestia -d >/dev/null 2>&1 || true
    ok "Shell reloaded"
elif have caelestia; then
    caelestia shell -r >/dev/null 2>&1 || true
    ok "Shell restarted"
else
    warn "Could not find 'qs' or 'caelestia' — reload the shell manually."
fi

printf '\n%s\n' "${G}${B}Done.${Z} Open the Caelestia dashboard and select the ${B}LocalSend${Z} tab."
printf '%s\n' "  • Press Scan, pick a device, then use Send Files / Folder / Clipboard / Text."
printf '%s\n' "  • Incoming transfers wait for you to Accept or Reject (never auto-accepted)."
