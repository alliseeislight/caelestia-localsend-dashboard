# Caelestia × LocalSend Dashboard

A native **[Caelestia](https://github.com/caelestia-dots/shell)** dashboard tab for
**[LocalSend](https://localsend.org)** — sending files, folders, the clipboard and
text to nearby devices, and receiving them with explicit Accept / Reject.

It is backed entirely by the headless **[localgo](https://github.com/bethropolis/localgo)**
daemon/CLI. **No LocalSend GUI is ever launched**, there is no taskbar entry and no
extra window: the whole thing lives inside your existing Caelestia dashboard and
matches its colours, typography, spacing, radii and animations.

> Status: works with Caelestia (`caelestia` Quickshell config) and `localgo` v0.6.7.

---

## Features

- **Nearby devices** — name, type icon, model/IP and Online/Offline state; select a target by clicking it.
- **Scan / Refresh** — event-driven by default; a manual scan runs `localgo discover` and *merges* the result with the daemon's device cache (a scan that finds nothing never clears the list).
- **Send files** — multi-select picker (`zenity`).
- **Send folder** — sent as a `.zip` (`localgo` compresses it).
- **Send clipboard** and **Send text** — text can be typed right in the widget.
- **Incoming transfers** with **Accept / Reject**. Fail-closed: nothing is ever accepted silently.
- **Live progress** for the outgoing transfer.
- **Recent history** of received transfers, read straight from `localgo`'s JSONL log.
- **Your own machine is hidden** — devices whose IP is one of this host's interface addresses (and the daemon's own fingerprint) are filtered out, so you can't accidentally "send to yourself".
- **Event-driven** incoming updates via the daemon's SSE stream — the listener only runs while the dashboard is open.
- **Start / stop** the receiver from the widget header.

---

## Requirements

| Dependency | Why | Notes |
|---|---|---|
| [Caelestia](https://github.com/caelestia-dots/shell) | the shell being extended | config at `~/.config/quickshell/caelestia` |
| [localgo](https://github.com/bethropolis/localgo) ≥ 0.6.7 | headless LocalSend protocol + IPC | installed automatically by `install.sh` |
| `zenity` | multi-file / folder pickers | `sudo pacman -S zenity` |
| `systemd` (user) | runs the receiver in the background | needed for receiving without a GUI |
| `curl`, `python3`, `tar` | runtime / installer | already present on most systems |

> **Do not run the LocalSend GUI at the same time.** It also uses port `53317`.
> The installer disables the GUI's autostart entry if it finds one.

---

## Installation

### Quick install

```bash
git clone https://github.com/alliseeislight/caelestia-localsend-dashboard.git
cd caelestia-localsend-dashboard
./install.sh
```

The installer is idempotent and makes timestamped backups of anything it touches.

### What the installer does, step by step

1. **Preflight** — checks that Caelestia, `systemd`, `curl`, `tar` and `python3` are present and warns if `zenity` is missing.
2. **Installs `localgo`** (if not already on your `PATH` or at `~/.local/bin/localgo`) by downloading the correct Linux release, verifying its SHA-256 checksum, and installing the binary to `~/.local/bin/localgo`.
3. **Installs the receiver service** — writes `~/.config/systemd/user/localgo.service`, then `systemctl --user enable --now localgo.service`. It listens on port `53317` and exposes a control socket at `~/.cache/localgo/ipc.sock`.
4. **Installs the widget** — copies `LocalSend.qml` → `~/.config/quickshell/caelestia/services/` and `LocalSendTab.qml` → `~/.config/quickshell/caelestia/modules/dashboard/`.
5. **Wires the tab in** — safely patches `modules/dashboard/Content.qml` to add a **LocalSend** tab (with a timestamped backup).
6. **Avoids the port clash** — if a LocalSend GUI autostart entry exists, it is renamed to `.disabled` (backup kept).
7. **Reloads the shell** — `qs -c caelestia kill; qs -c caelestia -d`.

### Manual installation

If you prefer to do it by hand, or the script doesn't fit your setup:

```bash
# 1. get localgo (or use your distro/AUR package)
mkdir -p ~/.local/bin
curl -fsSL https://github.com/bethropolis/localgo/releases/download/v0.6.7/localgo_0.6.7_linux_amd64.tar.gz \
  | tar -xz -C /tmp && install -m755 /tmp/localgo ~/.local/bin/localgo

# 2. the receiver user service
mkdir -p ~/.config/systemd/user
# edit systemd/localgo.service: replace @LOCALGO@ and @DOWNLOAD_DIR@
cp systemd/localgo.service ~/.config/systemd/user/localgo.service
systemctl --user daemon-reload
systemctl --user enable --now localgo.service

# 3. the widget files
mkdir -p ~/.config/quickshell/caelestia/services \
         ~/.config/quickshell/caelestia/modules/dashboard
cp config/services/LocalSend.qml                 ~/.config/quickshell/caelestia/services/
cp config/modules/dashboard/LocalSendTab.qml     ~/.config/quickshell/caelestia/modules/dashboard/

# 4. add the tab to Content.qml
python3 scripts/patch-content.py ~/.config/quickshell/caelestia/modules/dashboard/Content.qml

# 5. reload
qs -c caelestia kill; sleep 0.1; qs -c caelestia -d
```

`scripts/patch-content.py` is idempotent: it inserts the tab entry into the
`dashboardTabs` array and the `Component { id: localSendComponent }` block, and
does nothing if the file is already patched. (Back up `Content.qml` first!)

---

## Usage

1. Open the Caelestia dashboard (the drawer that contains Dashboard / Media / Performance / …).
2. Select the **LocalSend** tab.
3. Press **Scan** (or wait for the daemon's device cache). Click a device to select it.
4. Use **Send Files**, **Send Folder**, **Send Clipboard**, or type text and press **Send Text**.
5. When a device sends you something, it appears under **Incoming** — press **Accept** or **Reject**.

The header button starts/stops the receiver service.

---

## How it works

```
Dashboard (Caelestia)
   └─ LocalSendTab.qml          ← the panel: device list, actions, incoming, history
        └─ qs.services.LocalSend ← backend singleton
             ├─ HTTP over the Unix socket  (~/.cache/localgo/ipc.sock)
             │     /v1/status  /v1/devices  /v1/pending
             │     /v1/events (SSE, live transfers)
             │     /v1/transfer/accept|reject?pendingId=…
             └─ CLI for actions the socket doesn't expose
                   localgo send --json --ip <ip:port> …   (files / folder)
                   localgo send --stdin …                 (text)
                   localgo send --clipboard …             (clipboard)
                   localgo discover --quiet --json        (manual Scan)
        └─ zenity                     ← native multi-file / folder picker
```

- The daemon (`localgo serve --ipc`) is a **systemd user service**, so receiving works with no GUI and survives the shell restarting.
- The widget is **event-driven**: incoming transfers arrive over SSE while the tab is open, and the listener is torn down when it closes. There is no polling loop and no per-second process spawning.
- Nothing in this project launches `/opt/localsend/localsend` or opens a window.

---

## Configuration

- **Download directory** — the receiver writes to `~/Downloads` by default. To change it, edit `ExecStart=… --dir <path>` in `~/.config/systemd/user/localgo.service` and run `systemctl --user daemon-reload && systemctl --user restart localgo.service`.
- **Device alias / port / protocol** — configure via `localgo`'s own config (see `localgo --help` / `localgo serve --help`).
- **Auto-accept** — intentionally **not** enabled. Incoming transfers always require an explicit Accept.

---

## Troubleshooting

**The receiver didn't start / port 53317 is in use.**
Something else (usually the LocalSend GUI) holds the port. Close it, or disable its
autostart:
```bash
systemctl --user status localgo.service
ss -tlnp | grep 53317
```

**The LocalSend tab doesn't appear.**
Check `Content.qml` was patched and reload the shell:
```bash
grep -n localSendComponent ~/.config/quickshell/caelestia/modules/dashboard/Content.qml
qs -c caelestia kill; sleep 0.1; qs -c caelestia -d
```

**File/folder pickers do nothing.** Install `zenity` (`sudo pacman -S zenity`).

**No devices found.** Make sure the other device has LocalSend open and is on the
same network, then hit **Scan**. Discovery can take ~10–20 s.

**Send fails with `403 Forbidden`.** The receiver rejected the transfer — on the
other end it was declined, or the accept window (~30 s) expired.

---

## Uninstall

```bash
./uninstall.sh            # removes the widget + service, restores Content.qml
./uninstall.sh --purge    # also deletes ~/.local/bin/localgo and its cached data
```

Or manually:

```bash
systemctl --user disable --now localgo.service
rm -f ~/.config/systemd/user/localgo.service
systemctl --user daemon-reload
rm -f ~/.config/quickshell/caelestia/services/LocalSend.qml \
      ~/.config/quickshell/caelestia/modules/dashboard/LocalSendTab.qml
cp ~/.config/quickshell/caelestia/modules/dashboard/Content.qml.bak.* \
   ~/.config/quickshell/caelestia/modules/dashboard/Content.qml   # pick a backup
qs -c caelestia kill; sleep 0.1; qs -c caelestia -d
```

---

## Credits

- **[localgo](https://github.com/bethropolis/localgo)** by [bethropolis](https://github.com/bethropolis) — the headless LocalSend implementation and IPC socket that make this possible.
- **[Caelestia](https://github.com/caelestia-dots/shell)** — the shell and its design system.
- **[LocalSend](https://localsend.org)** — the protocol.

## License

[MIT](LICENSE) © alliseeislight
