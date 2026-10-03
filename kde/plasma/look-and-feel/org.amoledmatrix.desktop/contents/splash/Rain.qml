import QtQuick

Canvas {
    id: rain

    property int cell: 20
    property color head: "#c0ffd0"
    property color body: "#00ff41"
    property var drops: []
    readonly property string glyphs: "ｦｧｨｩｪｫｬｭｮｯｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ0123456789Z:.=*+-<>|"

    renderStrategy: Canvas.Threaded
    renderTarget: Canvas.FramebufferObject

    function glyph() {
        return glyphs.charAt(Math.floor(Math.random() * glyphs.length));
    }

    function reset() {
        var d = [];
        var rows = Math.ceil(height / cell);
        for (var i = 0; i < Math.ceil(width / cell); ++i)
            d.push(-Math.floor(Math.random() * rows));
        drops = d;
        var ctx = getContext("2d");
        if (ctx) {
            ctx.fillStyle = "#000000";
            ctx.fillRect(0, 0, width, height);
        }
    }

    onWidthChanged: reset()
    onHeightChanged: reset()

    onPaint: {
        var ctx = getContext("2d");
        // Translucent black over the last frame is what leaves the fading trail.
        ctx.fillStyle = "rgba(0, 0, 0, 0.08)";
        ctx.fillRect(0, 0, width, height);
        ctx.font = cell + "px 'Noto Sans Mono CJK JP', 'Noto Sans CJK JP', monospace";
        ctx.textBaseline = "top";
        var rows = Math.ceil(height / cell);
        for (var i = 0; i < drops.length; ++i) {
            var y = drops[i];
            if (y >= 0) {
                ctx.fillStyle = body;
                ctx.fillText(glyph(), i * cell, (y - 1) * cell);
                ctx.fillStyle = head;
                ctx.fillText(glyph(), i * cell, y * cell);
            }
            drops[i] = (y > rows && Math.random() > 0.975) ? 0 : y + 1;
        }
    }

    Timer {
        interval: 50
        running: rain.visible
        repeat: true
        onTriggered: rain.requestPaint()
    }
}
