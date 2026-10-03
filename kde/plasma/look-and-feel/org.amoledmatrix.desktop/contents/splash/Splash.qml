import QtQuick

Rectangle {
    id: root
    color: "#000000"

    property int stage
    property string message: "Wake up, Omar..."
    property int typed: 0

    Rain {
        anchors.fill: parent
        opacity: 0.6
    }

    Rectangle {
        anchors.centerIn: parent
        width: line.width + 64
        height: line.height + 32
        color: "#000000"
        opacity: 0.85
    }

    Text {
        id: line
        anchors.centerIn: parent
        text: root.message.substring(0, root.typed) + (cursor.on ? "█" : " ")
        color: "#00ff41"
        font.family: "Noto Sans Mono"
        font.pixelSize: 32
    }

    Timer {
        interval: 110
        running: root.typed < root.message.length
        repeat: true
        onTriggered: ++root.typed
    }

    Timer {
        id: cursor
        property bool on: true
        interval: 500
        running: true
        repeat: true
        onTriggered: on = !on
    }
}
