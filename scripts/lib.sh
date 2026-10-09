#!/usr/bin/env bash
# Shared helpers for install.sh / uninstall.sh.
#
# Locates the Caelestia shell config the same way Quickshell does. Quickshell
# resolves `qs -c caelestia` by scanning the `quickshell` subfolder of
# $XDG_CONFIG_HOME and then each entry of $XDG_CONFIG_DIRS (default /etc/xdg),
# and uses the first directory that contains a `shell.qml`.
#
# This means the same shell can live in several places:
#   * ~/.config/quickshell/caelestia        (git clone / manual, user-writable)
#   * /etc/xdg/quickshell/caelestia         (caelestia-shell AUR package, root-owned)
#   * <XDG_CONFIG_DIRS>/quickshell/caelestia (other XDG config dirs)
#   * /usr/local/share/quickshell/caelestia, /usr/share/quickshell/caelestia
#     (non-standard prefixes some builds/packagers use; Quickshell itself would
#      not load these, but copying one into the user config still fixes things)

# Print every candidate directory, one per line, in Quickshell's search order.
caelestia_candidates() {
    local home_config="${XDG_CONFIG_HOME:-$HOME/.config}"
    printf '%s\n' "$home_config/quickshell/caelestia"

    local dirs d
    IFS=':' read -r -a dirs <<< "${XDG_CONFIG_DIRS:-/etc/xdg}"
    for d in "${dirs[@]}"; do
        [ -n "$d" ] && printf '%s\n' "$d/quickshell/caelestia"
    done

    printf '%s\n' "/usr/local/share/quickshell/caelestia"
    printf '%s\n' "/usr/share/quickshell/caelestia"
}

# Print the first candidate Quickshell would load (contains shell.qml).
caelestia_active() {
    local d
    while IFS= read -r d; do
        if [ -f "$d/shell.qml" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done < <(caelestia_candidates)
    return 1
}

# Print the first candidate that actually contains this widget's files
# (used by the uninstaller to find what it installed).
caelestia_with_widget() {
    local d
    while IFS= read -r d; do
        if [ -f "$d/services/LocalSend.qml" ] || [ -f "$d/modules/dashboard/LocalSendTab.qml" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done < <(caelestia_candidates)
    return 1
}
