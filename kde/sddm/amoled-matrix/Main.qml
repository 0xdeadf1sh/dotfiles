import QtQuick

Rectangle {
    id: root
    color: "#000000"

    readonly property color green: "#00ff41"
    readonly property color dim: "#159a38"
    readonly property string mono: "Noto Sans Mono"
    property int session: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

    function login() {
        status.text = "";
        sddm.login(user.text, pass.text, session);
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            pass.text = "";
            status.text = "ACCESS DENIED";
            pass.forceActiveFocus();
        }
    }

    Rain {
        anchors.fill: parent
        opacity: 0.5
    }

    Rectangle {
        anchors.centerIn: parent
        width: 520
        height: form.height + 64
        color: "#000000"
        border.color: root.dim
        border.width: 1

        Column {
            id: form
            anchors.centerIn: parent
            width: parent.width - 64
            spacing: 18

            Text {
                text: Qt.formatDateTime(clock.now, "yyyy-MM-dd  HH:mm:ss")
                color: root.dim
                font.family: root.mono
                font.pixelSize: 16
            }

            Row {
                spacing: 12
                Text { text: "user>"; color: root.dim; font.family: root.mono; font.pixelSize: 24 }
                TextInput {
                    id: user
                    width: form.width - 90
                    text: userModel.lastUser
                    color: root.green
                    selectionColor: root.dim
                    font.family: root.mono
                    font.pixelSize: 24
                    clip: true
                    KeyNavigation.tab: pass
                    onAccepted: pass.forceActiveFocus()
                }
            }

            Row {
                spacing: 12
                Text { text: "pass>"; color: root.dim; font.family: root.mono; font.pixelSize: 24 }
                TextInput {
                    id: pass
                    width: form.width - 90
                    echoMode: TextInput.Password
                    passwordCharacter: "*"
                    color: root.green
                    selectionColor: root.dim
                    font.family: root.mono
                    font.pixelSize: 24
                    clip: true
                    focus: true
                    cursorDelegate: Rectangle {
                        width: 12
                        color: root.green
                        SequentialAnimation on opacity {
                            loops: Animation.Infinite
                            NumberAnimation { to: 0; duration: 500 }
                            NumberAnimation { to: 1; duration: 500 }
                        }
                    }
                    KeyNavigation.backtab: user
                    onAccepted: root.login()
                }
            }

            Text {
                id: status
                color: "#ff3b3b"
                font.family: root.mono
                font.pixelSize: 18
                height: 22
            }

            Item {
                width: form.width
                height: 24

                Text {
                    id: sessionLabel
                    color: sessionMouse.containsMouse ? root.green : root.dim
                    font.family: root.mono
                    font.pixelSize: 16
                    text: "[" + (names.count > root.session ? names.itemAt(root.session).name : "?") + "]"

                    Repeater {
                        id: names
                        model: sessionModel
                        delegate: Item { property string name: model.name }
                    }

                    MouseArea {
                        id: sessionMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.session = (root.session + 1) % names.count
                    }
                }

                Row {
                    anchors.right: parent.right
                    spacing: 16
                    Repeater {
                        model: [
                            { label: "suspend", ok: sddm.canSuspend, run: function () { sddm.suspend(); } },
                            { label: "reboot", ok: sddm.canReboot, run: function () { sddm.reboot(); } },
                            { label: "halt", ok: sddm.canPowerOff, run: function () { sddm.powerOff(); } }
                        ]
                        delegate: Text {
                            visible: modelData.ok
                            text: modelData.label
                            color: mouse.containsMouse ? root.green : root.dim
                            font.family: root.mono
                            font.pixelSize: 16
                            MouseArea {
                                id: mouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: modelData.run()
                            }
                        }
                    }
                }
            }
        }
    }

    Timer {
        id: clock
        property date now: new Date()
        interval: 1000
        running: true
        repeat: true
        onTriggered: now = new Date()
    }
}
