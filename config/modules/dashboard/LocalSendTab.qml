pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services

// A native Caelestia dashboard panel for LocalSend, backed by the headless
// `localgo` daemon/CLI (see qs.services.LocalSend). No application window,
// no taskbar entry and no GUI is launched.
Item {
    id: root

    implicitWidth: 840
    implicitHeight: 500

    // Selected destination, stored as "ip:port" so it survives discovery refreshes
    property string target: ""
    // Human-readable name of the selected device, for display only
    property string targetName: ""

    Component.onCompleted: LocalSend.active = true
    Component.onDestruction: LocalSend.active = false

    function deviceIcon(type: string): string {
        switch (type) {
        case "mobile":
            return "smartphone";
        case "desktop":
            return "computer";
        case "web":
            return "language";
        case "headless":
            return "dns";
        case "server":
            return "dns";
        default:
            return "devices";
        }
    }

    function formatSize(n: real): string {
        if (!n || n <= 0)
            return "";
        const units = ["B", "KiB", "MiB", "GiB", "TiB"];
        let i = 0;
        let v = n;
        while (v >= 1024 && i < units.length - 1) {
            v /= 1024;
            i++;
        }
        return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
    }

    function formatTime(ts: string): string {
        const d = new Date(ts);
        return isNaN(d.getTime()) ? "" : d.toLocaleTimeString(undefined, {
            hour: "2-digit",
            minute: "2-digit"
        });
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.medium

        // ── Header ────────────────────────────────────────────────────────
        StyledRect {
            Layout.fillWidth: true
            implicitHeight: header.implicitHeight + Tokens.padding.medium * 2
            color: Colours.palette.m3surfaceContainer
            radius: Tokens.rounding.large

            RowLayout {
                id: header

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.medium
                spacing: Tokens.spacing.small

                MaterialIcon {
                    text: "wifi_tethering"
                    color: Colours.palette.m3primary
                    fontStyle: Tokens.font.icon.large
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    StyledText {
                        text: Tr.tr("LocalSend")
                        font: Tokens.font.body.builders.large.weight(Font.DemiBold).build()
                    }

                    StyledText {
                        text: LocalSend.backendUp ? Tr.tr("Receiving as %1").arg(LocalSend.alias) : Tr.tr("Receiver not running")
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.small
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }

                StyledRect {
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: Tokens.rounding.full
                    color: LocalSend.backendUp ? Colours.palette.m3primary : Colours.palette.m3error
                }

                StyledText {
                    text: LocalSend.backendUp ? Tr.tr("Ready") : Tr.tr("Offline")
                    color: LocalSend.backendUp ? Colours.palette.m3primary : Colours.palette.m3error
                    font: Tokens.font.body.small
                }

                IconTextButton {
                    visible: !LocalSend.backendUp
                    icon: "play_arrow"
                    text: Tr.tr("Start")
                    type: IconTextButton.Tonal
                    onClicked: {
                        Quickshell.execDetached(["systemctl", "--user", "start", "localgo.service"]);
                        startTimer.restart();
                    }
                }
            }
        }

        // ── Main body ─────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Tokens.spacing.medium

            // Left: nearby devices
            StyledRect {
                Layout.preferredWidth: 300
                Layout.fillHeight: true
                color: Colours.palette.m3surfaceContainer
                radius: Tokens.rounding.large

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Tokens.padding.medium
                    spacing: Tokens.spacing.small

                    RowLayout {
                        Layout.fillWidth: true

                        StyledText {
                            text: Tr.tr("Nearby Devices")
                            font: Tokens.font.body.builders.medium.weight(Font.DemiBold).build()
                            Layout.fillWidth: true
                        }

                        IconButton {
                            icon: "refresh"
                            type: IconButton.Text
                            disabled: LocalSend.scanning
                            onClicked: LocalSend.discover()
                        }
                    }

                    StyledText {
                        visible: LocalSend.devices.length === 0
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        wrapMode: Text.WordWrap
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.small
                        text: LocalSend.scanning ? Tr.tr("Scanning…") : Tr.tr("No devices found.\nMake sure LocalSend is open on the other device.")
                    }

                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        visible: LocalSend.devices.length > 0
                        clip: true
                        spacing: Tokens.spacing.extraSmall
                        model: LocalSend.devices
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: StyledRect {
                            id: deviceRow

                            required property var modelData

                            readonly property string ip: `${modelData.ip}:${modelData.port}`
                            readonly property bool selected: root.target === ip

                            width: ListView.view.width
                            implicitHeight: deviceLayout.implicitHeight + Tokens.padding.small * 2
                            radius: Tokens.rounding.medium
                            color: selected ? Colours.palette.m3secondaryContainer : "transparent"

                            RowLayout {
                                id: deviceLayout

                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.margins: Tokens.padding.small
                                spacing: Tokens.spacing.small

                                MaterialIcon {
                                    text: root.deviceIcon(modelData.deviceType)
                                    color: selected ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
                                    fontStyle: Tokens.font.icon.medium
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    StyledText {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: modelData.alias
                                        font: Tokens.font.body.medium
                                        color: selected ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: modelData.deviceModel ? `${modelData.deviceModel} · ${modelData.ip}` : modelData.ip
                                        font: Tokens.font.body.small
                                        color: Colours.palette.m3onSurfaceVariant
                                    }
                                }

                                StyledText {
                                    text: modelData.available ? Tr.tr("Online") : Tr.tr("Offline")
                                    font: Tokens.font.body.small
                                    color: modelData.available ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                                }
                            }

                            StateLayer {
                                radius: deviceRow.radius
                                onClicked: {
                                    if (root.target === deviceRow.ip) {
                                        root.target = "";
                                        root.targetName = "";
                                    } else {
                                        root.target = deviceRow.ip;
                                        root.targetName = modelData.alias;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Right column
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Tokens.spacing.medium

                // Actions
                StyledRect {
                    Layout.fillWidth: true
                    implicitHeight: actions.implicitHeight + Tokens.padding.medium * 2
                    color: Colours.palette.m3surfaceContainer
                    radius: Tokens.rounding.large

                    ColumnLayout {
                        id: actions

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Tokens.padding.medium
                        spacing: Tokens.spacing.small

                        StyledText {
                            text: root.target.length > 0 ? Tr.tr("Send to %1").arg(root.targetName.length > 0 ? root.targetName : root.target) : Tr.tr("Select a device")
                            font: Tokens.font.body.builders.medium.weight(Font.DemiBold).build()
                            color: root.target.length > 0 ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.spacing.small

                            IconTextButton {
                                Layout.fillWidth: true
                                icon: "upload_file"
                                text: Tr.tr("Send Files")
                                type: IconTextButton.Tonal
                                disabled: root.target.length === 0 || LocalSend.sending
                                onClicked: LocalSend.pickFiles(root.target)
                            }

                            IconTextButton {
                                Layout.fillWidth: true
                                icon: "folder"
                                text: Tr.tr("Send Folder")
                                type: IconTextButton.Tonal
                                disabled: root.target.length === 0 || LocalSend.sending
                                onClicked: LocalSend.pickFolder(root.target)
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.spacing.small

                            StyledTextField {
                                id: textField

                                Layout.fillWidth: true
                                type: StyledTextField.Filled
                                radius: Tokens.rounding.medium
                                placeholderText: Tr.tr("Text to send")
                                horizontalPadding: Tokens.padding.medium
                                verticalPadding: Tokens.padding.small
                                font: Tokens.font.body.small
                                onAccepted: {
                                    if (text.length > 0 && root.target.length > 0) {
                                        LocalSend.sendText(root.target, text);
                                        text = "";
                                    }
                                }
                            }

                            IconTextButton {
                                icon: "send"
                                text: Tr.tr("Send Text")
                                type: IconTextButton.Tonal
                                disabled: root.target.length === 0 || textField.text.length === 0 || LocalSend.sending
                                onClicked: {
                                    LocalSend.sendText(root.target, textField.text);
                                    textField.text = "";
                                }
                            }

                            IconButton {
                                icon: "content_paste"
                                type: IconButton.Tonal
                                disabled: root.target.length === 0 || LocalSend.sending
                                onClicked: LocalSend.sendClipboard(root.target)
                            }
                        }
                    }
                }

                // Incoming / active transfers
                StyledRect {
                    Layout.fillWidth: true
                    implicitHeight: transfers.implicitHeight + Tokens.padding.medium * 2
                    visible: LocalSend.pending.length > 0 || LocalSend.sending || LocalSend.sendError.length > 0
                    color: Colours.palette.m3surfaceContainer
                    radius: Tokens.rounding.large

                    ColumnLayout {
                        id: transfers

                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Tokens.padding.medium
                        spacing: Tokens.spacing.small

                        StyledText {
                            visible: LocalSend.pending.length > 0
                            text: Tr.tr("Incoming")
                            font: Tokens.font.body.builders.medium.weight(Font.DemiBold).build()
                        }

                        Repeater {
                            model: LocalSend.pending

                            delegate: RowLayout {
                                required property var modelData

                                Layout.fillWidth: true
                                spacing: Tokens.spacing.small

                                MaterialIcon {
                                    text: modelData.clipboard ? "content_paste" : "download"
                                    color: Colours.palette.m3primary
                                    fontStyle: Tokens.font.icon.medium
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    StyledText {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: modelData.senderAlias
                                        font: Tokens.font.body.medium
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: modelData.files.length === 1 ? modelData.files[0].name : Tr.tr("%1 files").arg(modelData.files.length)
                                        font: Tokens.font.body.small
                                        color: Colours.palette.m3onSurfaceVariant
                                    }
                                }

                                IconButton {
                                    icon: "close"
                                    type: IconButton.Text
                                    onClicked: LocalSend.reject(modelData.pendingId)
                                }

                                IconTextButton {
                                    icon: "check"
                                    text: Tr.tr("Accept")
                                    type: IconTextButton.Filled
                                    onClicked: LocalSend.accept(modelData.pendingId)
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: LocalSend.sending
                            spacing: Tokens.spacing.extraSmall

                            RowLayout {
                                Layout.fillWidth: true

                                StyledText {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: Tr.tr("Sending %1").arg(LocalSend.sendFile || LocalSend.sendLabel)
                                    font: Tokens.font.body.small
                                }

                                StyledText {
                                    text: `${Math.round(LocalSend.sendPercent)}%`
                                    font: Tokens.font.body.small
                                    color: Colours.palette.m3onSurfaceVariant
                                }
                            }

                            StyledProgressBar {
                                Layout.fillWidth: true
                                implicitHeight: Tokens.padding.small
                                value: LocalSend.sendPercent / 100
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            visible: LocalSend.sendError.length > 0
                            wrapMode: Text.WordWrap
                            text: LocalSend.sendError
                            font: Tokens.font.body.small
                            color: Colours.palette.m3error
                        }
                    }
                }

                // Recent transfers
                StyledRect {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    color: Colours.palette.m3surfaceContainer
                    radius: Tokens.rounding.large

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Tokens.padding.medium
                        spacing: Tokens.spacing.small

                        StyledText {
                            text: Tr.tr("Recent")
                            font: Tokens.font.body.builders.medium.weight(Font.DemiBold).build()
                        }

                        StyledText {
                            visible: LocalSend.history.length === 0
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            color: Colours.palette.m3onSurfaceVariant
                            font: Tokens.font.body.small
                            text: Tr.tr("No transfers yet")
                        }

                        ListView {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: LocalSend.history.length > 0
                            clip: true
                            spacing: Tokens.spacing.extraSmall
                            model: LocalSend.history
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: RowLayout {
                                id: historyRow

                                required property var modelData

                                width: ListView.view.width
                                spacing: Tokens.spacing.small

                                MaterialIcon {
                                    text: modelData.status === "failed" ? "error" : (modelData.status === "clipboard" ? "content_paste" : "download")
                                    color: modelData.status === "failed" ? Colours.palette.m3error : Colours.palette.m3primary
                                    fontStyle: Tokens.font.icon.small
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    StyledText {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: modelData.file_name || modelData.sender_alias
                                        font: Tokens.font.body.small
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        text: `${modelData.sender_alias} · ${root.formatSize(modelData.file_size)}`
                                        font: Tokens.font.body.small
                                        color: Colours.palette.m3onSurfaceVariant
                                    }
                                }

                                StyledText {
                                    text: modelData.status === "failed" ? Tr.tr("Failed") : Tr.tr("Done")
                                    font: Tokens.font.body.small
                                    color: modelData.status === "failed" ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                                }

                                StyledText {
                                    text: root.formatTime(modelData.timestamp)
                                    font: Tokens.font.body.small
                                    color: Colours.palette.m3onSurfaceVariant
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Timer {
        id: startTimer

        interval: 1500
        onTriggered: LocalSend.refreshAll()
    }
}