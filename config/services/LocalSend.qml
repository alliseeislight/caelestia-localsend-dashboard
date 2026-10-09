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

    property var rawDevices: []
    readonly property var devices: {
        const selfFp = root.status ? root.status.fingerprint : "";
        return root.rawDevices.filter(x => x && (!selfFp || x.fingerprint !== selfFp));
    }
    property var pending: []
    property var history: []
    property bool scanning: false

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
        sendProc.command = [root.bin, "send", "--json", "--ip", target].concat(zip ? ["--zip"] : []).concat(paths);
        sendProc.running = true;
    }

    function sendClipboard(target: string): void {
        if (!target) {
            root.lastMessage = qsTr("Select a device first");
            return;
        }
        root.beginSend(target, qsTr("Clipboard"));
        sendProc.command = [root.bin, "send", "--json", "--clipboard", "--ip", target];
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
                root.rawDevices = d;
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

        command: [root.bin, "discover", "--quiet", "--json", "--timeout", "6"]
        stdout: StdioCollector {
            id: discoverOut
            waitForEnd: true
            onStreamFinished: {
                // `localgo discover --json` prints human-readable progress
                // (including spinner/ANSI output) before the JSON document,
                // so slice from the first opening brace and parse from there.
                const text = discoverOut.text;
                const start = text.indexOf("{");
                if (start < 0)
                    return;
                try {
                    const d = JSON.parse(text.slice(start));
                    if (Array.isArray(d.devices))
                        root.rawDevices = d.devices;
                    else if (typeof d.count === "number" && d.count === 0)
                        root.rawDevices = [];
                } catch (e) {
                    // discovery may print human-readable logs; ignore those
                }
            }
        }
        onExited: (code, status) => { // qmllint disable signal-handler-parameters
            root.scanning = false;
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

        command: ["sh", "-c", `printf %s "$1" | "${root.bin}" send --json --stdin --ip "$2"`, "sh", textProc.payload, textProc.target]
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