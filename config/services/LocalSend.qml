pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Backend bridge between the Caelestia dashboard and the (headless) LocalSend
// protocol implementation `localgo`. It talks to the running `localgo serve`
// daemon over its Unix control socket and shells out to the CLI for actions
// that the daemon does not expose (discovery, sending).
//
// Nothing here launches the LocalSend GUI and nothing creates a window.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string bin: `${root.home}/.local/bin/localgo`
    readonly property string cacheRoot: Quickshell.env("XDG_CACHE_HOME") || `${root.home}/.cache`
    readonly property string dataRoot: Quickshell.env("XDG_DATA_HOME") || `${root.home}/.local/share`
    readonly property string sock: `${root.cacheRoot}/localgo/ipc.sock`
    readonly property string historyFile: `${root.dataRoot}/localgo/history.jsonl`

    // Set to true while the dashboard tab is mounted so every timer below can
    // idle completely when the tab is not visible.
    property bool active: false

    property bool backendUp: false
    property var status: ({})
    readonly property string alias: root.status && root.status.alias ? root.status.alias : root.home.split("/").pop()
    readonly property string downloadDir: root.status && root.status.downloadDir ? root.status.downloadDir : ""

    // Device sources. `cacheDevices` comes from the daemon's passive cache
    // (/v1/devices); `scanDevices` from an explicit `localgo discover`. They
    // are merged (never replaced wholesale) so a scan that finds nothing can
    // no longer wipe a known-good list.
    property var cacheDevices: []
    property var scanDevices: []

    // IPv4 addresses belonging to this machine. localgo's own announcement can
    // carry a *different* fingerprint than /v1/status (e.g. when it goes out
    // over the docker0 bridge), so the fingerprint check alone leaves us
    // visible in our own device list. Filtering by local IP always hides us.
    property var localIps: []

    readonly property var devices: {
        const selfFp = root.status ? root.status.fingerprint : "";
        const locals = root.localIps;
        const seen = {};
        const out = [];
        const add = d => {
            if (!d || !d.ip)
                return;
            if (selfFp && d.fingerprint === selfFp)
                return;
            if (locals.indexOf(d.ip) !== -1)
                return;
            const k = `${d.ip}:${d.port}`;
            if (seen[k])
                return;
            seen[k] = true;
            out.push(d);
        };
        // Scan results are the freshest, so take them first.
        root.scanDevices.forEach(add);
        root.cacheDevices.forEach(add);
        return out;
    }
    property var pending: []
    property var history: []
    property bool scanning: false

    // Reactive clock (ms). Lets the "last seen" label age on screen without any
    // network traffic; it only ticks while the dashboard tab is open.
    property double nowMs: Date.now()

    // localgo bounds the whole send (discovery + waiting for the receiver to
    // Accept + upload) with this timeout, defaulting to 30s. That is far too
    // short: a human accepting on the phone, or a large file over Wi-Fi,
    // exceeded it and produced "prepare request cancelled: context deadline
    // exceeded". 10 minutes covers normal accepts and transfers while still
    // failing in bounded time; unreachable hosts fail fast regardless.
    readonly property int sendTimeoutSec: 600

    // Outgoing transfer state
    property bool sending: false
    property string sendTarget: ""
    property string sendLabel: ""
    property string sendFile: ""
    property int sendPercent: 0
    property bool sendFailed: false
    property string sendError: ""
    property string lastMessage: ""

    // ---------------------------------------------------------------- helpers
    function encodeId(id): string {
        return encodeURIComponent(id ?? "");
    }

    // ── Device freshness ─────────────────────────────────────────────────────
    // localgo caches peers for 14 days and only probes them once at startup, so
    // its `available` flag can stay true long after a device has gone. Prefer
    // the last time we actually heard from the device.
    readonly property int onlineWindowMs: 300000 // 5 minutes

    function lastSeenAgeMs(d): double {
        if (!d || !d.lastSeen)
            return -1;
        // localgo timestamps carry nanosecond precision; trim to milliseconds
        // so every JS engine's Date.parse accepts them.
        const s = String(d.lastSeen).replace(/(\.\d{3})\d+/, "$1");
        const t = Date.parse(s);
        return isNaN(t) ? -1 : (root.nowMs - t);
    }

    function deviceOnline(d): bool {
        if (!d || !d.available)
            return false;
        const age = root.lastSeenAgeMs(d);
        return age < 0 || age < root.onlineWindowMs;
    }

    function deviceStateText(d): string {
        if (!d)
            return "";
        if (!d.available)
            return qsTr("Offline");
        const age = root.lastSeenAgeMs(d);
        if (age < 0 || age < root.onlineWindowMs)
            return qsTr("Online");
        const mins = Math.max(1, Math.floor(age / 60000));
        if (mins < 60)
            return qsTr("Seen %1m ago").arg(mins);
        const hrs = Math.floor(mins / 60);
        if (hrs < 24)
            return qsTr("Seen %1h ago").arg(hrs);
        return qsTr("Seen %1d ago").arg(Math.floor(hrs / 24));
    }

    function refreshStatus(): void {
        statusIpc.running = true;
    }

    function refreshDevices(): void {
        devicesIpc.running = true;
    }

    function refreshPending(): void {
        pendingIpc.running = true;
    }

    function refreshAll(): void {
        statusIpc.running = true;
        devicesIpc.running = true;
        pendingIpc.running = true;
        localIpsProc.running = true;
        historyView.reload();
    }

    // Active network discovery. This is only triggered on demand (the daemon
    // already refreshes its device cache in the background).
    function discover(): void {
        root.scanning = true;
        discoverProc.running = true;
    }

    function accept(id: string): void {
        acceptIpc.endpoint = `/v1/transfer/accept?pendingId=${encodeURIComponent(id ?? "")}`;
        acceptIpc.running = true;
    }

    function reject(id: string): void {
        rejectIpc.endpoint = `/v1/transfer/reject?pendingId=${encodeURIComponent(id ?? "")}`;
        rejectIpc.running = true;
    }

    function pickFiles(target: string): void {
        if (!target) {
            root.lastMessage = qsTr("Select a device first");
            return;
        }
        picker.target = target;
        picker.folder = false;
        picker.running = true;
    }

    function pickFolder(target: string): void {
        if (!target) {
            root.lastMessage = qsTr("Select a device first");
            return;
        }
        picker.target = target;
        picker.folder = true;
        picker.running = true;
    }

    function sendPaths(target: string, paths: var, zip: bool): void {
        if (!target || !paths || paths.length === 0)
            return;

        root.beginSend(target, paths.length === 1 ? paths[0].split("/").pop() : qsTr("%1 items").arg(paths.length));
        sendProc.command = [root.bin, "send", "--json", "--timeout", String(root.sendTimeoutSec), "--ip", target].concat(zip ? ["--zip"] : []).concat(paths);
        sendProc.running = true;
    }

    function sendClipboard(target: string): void {
        if (!target) {
            root.lastMessage = qsTr("Select a device first");
            return;
        }
        root.beginSend(target, qsTr("Clipboard"));
        sendProc.command = [root.bin, "send", "--json", "--timeout", String(root.sendTimeoutSec), "--clipboard", "--ip", target];
        sendProc.running = true;
    }

    function sendText(target: string, text: string): void {
        if (!target)
            return;
        if (!text || text.trim().length === 0)
            return;

        root.beginSend(target, qsTr("Text"));
        textProc.target = target;
        textProc.payload = text;
        textProc.running = true;
    }

    function beginSend(target: string, label: string): void {
        root.sending = true;
        root.sendFailed = false;
        root.sendError = "";
        root.sendPercent = 0;
        root.sendTarget = target;
        root.sendLabel = label;
        root.sendFile = "";
        root.lastMessage = "";
    }

    function handleSendLine(line: string): void {
        let ev;
        try {
            ev = JSON.parse(line);
        } catch (e) {
            return;
        }
        if (!ev || !ev.type)
            return;

        switch (ev.type) {
        case "transfer_start":
            root.sendFile = ev.file || root.sendLabel;
            root.sendPercent = 0;
            break;
        case "progress":
            if (ev.file)
                root.sendFile = ev.file;
            if (typeof ev.percent === "number")
                root.sendPercent = Math.max(0, Math.min(100, Math.round(ev.percent)));
            break;
        case "file_complete":
            break;
        case "success":
            root.sendPercent = 100;
            root.sendFailed = false;
            root.lastMessage = qsTr("Sent to %1").arg(root.sendTarget);
            break;
        case "error":
            root.sendFailed = true;
            root.sendError = ev.error || qsTr("Transfer failed");
            break;
        case "pin_required":
            root.sendFailed = true;
            root.sendError = qsTr("Device requires a PIN");
            break;
        case "transfer_cancelled":
            root.sendFailed = true;
            root.sendError = qsTr("Cancelled");
            break;
        }
    }

    onActiveChanged: {
        if (root.active) {
            root.refreshAll();
            eventsProc.running = true;
        } else {
            eventsProc.running = false;
            eventsTimer.stop();
            pendingSoonTimer.stop();
        }
    }

    // A failed outgoing send leaves its error in the transfers card. Clear it
    // after a while so a stale send error can't be mistaken for the result of
    // a later incoming transfer.
    onSendErrorChanged: {
        if (root.sendError.length > 0)
            sendErrorClear.restart();
    }

    Timer {
        id: sendErrorClear
        interval: 15000
        onTriggered: {
            root.sendError = "";
            root.sendFailed = false;
        }
    }

    // Keeps the "last seen" labels current while the dashboard is open.
    Timer {
        id: clockTimer
        interval: 30000
        repeat: true
        running: root.active
        onTriggered: root.nowMs = Date.now()
    }

    // ── Live events (server-sent events over the control socket) ─────────────
    // Event-driven instead of polling: the daemon pushes transfer events while
    // the dashboard is open, and the listener is torn down when it closes.
    function handleEventLine(line: string): void {
        const prefix = "data: ";
        if (line.indexOf(prefix) !== 0)
            return;
        let ev = null;
        try {
            ev = JSON.parse(line.slice(prefix.length));
        } catch (e) {
            return;
        }
        if (!ev || typeof ev.type !== "string")
            return;
        root.backendUp = true;
        if (ev.type.indexOf("transfer") === 0)
            pendingSoonTimer.restart();
    }

    Timer {
        id: pendingSoonTimer
        interval: 150
        onTriggered: pendingIpc.running = true
    }

    // --- IPC queries (one-shot curl against the control socket) -------------
    component Ipc: Process {
        id: ipc
        property string endpoint: "/v1/status"
        property var handle
        property var onFinished: null
        command: ["curl", "-sS", "--max-time", "4", "--unix-socket", root.sock, "http://ipc" + ipc.endpoint]
        stdout: StdioCollector {
            id: ipcOut
            waitForEnd: true
            onStreamFinished: {
                if (!ipc.handle)
                    return;
                let parsed = null;
                try {
                    parsed = JSON.parse(ipcOut.text);
                } catch (e) {
                    parsed = null;
                }
                ipc.handle(parsed);
            }
        }
        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            root.backendUp = code === 0;
            if (ipc.onFinished)
                ipc.onFinished(code);
        }
    }

    Ipc {
        id: statusIpc
        endpoint: "/v1/status"
        handle: d => {
            root.status = d && typeof d === "object" ? d : ({});
        }
    }

    Ipc {
        id: devicesIpc
        endpoint: "/v1/devices"
        handle: d => {
            if (Array.isArray(d))
                root.cacheDevices = d;
        }
    }

    Ipc {
        id: pendingIpc
        endpoint: "/v1/pending"
        handle: d => {
            root.pending = Array.isArray(d) ? d : [];
        }
    }

    // --- Accept / reject are one-shot curl with a dynamic endpoint ----------
    Ipc {
        id: acceptIpc
        onFinished: () => pendingSoonTimer.restart()
    }

    Ipc {
        id: rejectIpc
        onFinished: () => pendingSoonTimer.restart()
    }

    // --- Long-lived SSE listener (see handleEventLine above) -----------------
    Process {
        id: eventsProc

        command: ["curl", "-sS", "-N", "--unix-socket", root.sock, "http://ipc/v1/events"]
        stdout: SplitParser {
            onRead: line => root.handleEventLine(line)
        }
        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            // Reconnect while the dashboard is open (daemon restarts, etc.).
            if (root.active)
                eventsTimer.restart();
        }
    }

    Timer {
        id: eventsTimer
        interval: 2000
        onTriggered: {
            if (root.active && !eventsProc.running)
                eventsProc.running = true;
        }
    }

    // --- Discovery (only started explicitly) --------------------------------
    Process {
        id: discoverProc

        command: [root.bin, "discover", "--quiet", "--json", "--timeout", "8"]
        stdout: StdioCollector {
            id: discoverOut
            waitForEnd: true
            onStreamFinished: {
                // `localgo discover --json` prints human-readable progress
                // (including spinner/ANSI output) before the JSON document,
                // so slice from the first opening brace and parse from there.
                // Never wipe the cached list: discover routinely returns
                // {"count": 0, "devices": null} when the subnet scan finds
                // nothing, and clearing on that hid devices the daemon knew.
                const text = discoverOut.text;
                const start = text.indexOf("{");
                let found = [];
                if (start >= 0) {
                    try {
                        const d = JSON.parse(text.slice(start));
                        if (Array.isArray(d.devices))
                            found = d.devices;
                    } catch (e) {
                        // discovery may print human-readable logs; ignore those
                    }
                }
                root.scanDevices = found;
                // Pull in whatever the daemon learned meanwhile.
                devicesIpc.running = true;
                localIpsProc.running = true;
            }
        }
        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            root.scanning = false;
        }
    }

    // --- Local interface addresses (used to hide ourselves) -----------------
    Process {
        id: localIpsProc

        command: ["ip", "-j", "-4", "addr", "show"]
        stdout: StdioCollector {
            id: localIpsOut
            waitForEnd: true
            onStreamFinished: {
                const ips = [];
                try {
                    const ifaces = JSON.parse(localIpsOut.text);
                    for (const iface of ifaces) {
                        for (const a of (iface.addr_info || [])) {
                            if (a.family === "inet" && a.local)
                                ips.push(a.local);
                        }
                    }
                } catch (e) {
                    // `ip` missing or non-JSON output: leave the list empty and
                    // fall back to the fingerprint check.
                }
                root.localIps = ips;
            }
        }
    }

    // --- Sending files / folders --------------------------------------------
    Process {
        id: sendProc

        command: [root.bin, "send", "--json"]
        stdout: SplitParser {
            onRead: line => root.handleSendLine(line)
        }
        stderr: StdioCollector {
            id: sendErr
        }
        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            root.sending = false;
            if (code !== 0) {
                root.sendFailed = true;
                const e = sendErr.text.trim();
                if (e.length > 0)
                    root.sendError = e;
                else if (!root.sendError)
                    root.sendError = qsTr("Transfer failed");
            } else if (!root.sendFailed) {
                root.sendPercent = 100;
            }
        }
    }

    // --- Sending text via stdin ---------------------------------------------
    Process {
        id: textProc

        property string target: ""
        property string payload: ""

        command: ["sh", "-c", `printf %s "$1" | "${root.bin}" send --json --timeout ${root.sendTimeoutSec} --stdin --ip "$2"`, "sh", textProc.payload, textProc.target]
        stdout: SplitParser {
            onRead: line => root.handleSendLine(line)
        }
        stderr: StdioCollector {
            id: textErr
        }
        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            root.sending = false;
            if (code !== 0) {
                root.sendFailed = true;
                const e = textErr.text.trim();
                if (e.length > 0)
                    root.sendError = e;
                else if (!root.sendError)
                    root.sendError = qsTr("Transfer failed");
            } else if (!root.sendFailed) {
                root.sendPercent = 100;
            }
        }
    }

    // --- zenity file / folder picker ----------------------------------------
    Process {
        id: picker

        property string target: ""
        property bool folder: false

        command: picker.folder ? ["zenity", "--file-selection", "--directory", "--title=Select a folder to send"] : ["zenity", "--file-selection", "--multiple", "--separator=\n", "--title=Select files to send"]
        stdout: StdioCollector {
            id: pickerOut
            waitForEnd: true
            onStreamFinished: {
                const out = pickerOut.text;
                if (!out || out.trim().length === 0)
                    return;
                if (picker.folder) {
                    root.sendPaths(picker.target, [out.trim()], true);
                } else {
                    const files = out.split("\n").map(s => s.trim()).filter(s => s.length > 0);
                    root.sendPaths(picker.target, files, false);
                }
            }
        }
    }

    // --- History: read the daemon's append-only JSONL log file ---------------
    FileView {
        id: historyView

        path: root.historyFile
        watchChanges: true
        printErrors: false

        onTextChanged: root.parseHistory()
        onLoaded: root.parseHistory()
        onLoadFailed: root.history = []
    }

    function parseHistory(): void {
        let text = "";
        try {
            text = historyView.text();
        } catch (e) {
            root.history = [];
            return;
        }
        const lines = (text || "").split("\n").filter(l => l.trim().length > 0);
        const out = [];
        for (let i = lines.length - 1; i >= 0 && out.length < 20; i--) {
            try {
                out.push(JSON.parse(lines[i]));
            } catch (e) {
                // skip malformed lines
            }
        }
        root.history = out;
    }
}