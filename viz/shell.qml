// Jarvis visualizer — a click-through overlay shown while Jarvis speaks.
// Arc-reactor core, mirrored audio-reactive bars driven by a precomputed
// loudness envelope, and a caption of what is being said.
//
// Driven over IPC by bin/jarvis-say:
//   qs -p <this dir> ipc call viz speak "<lvl,lvl,...>"   (20 levels/s, 0..1)
//   qs -p <this dir> ipc call viz stop
// The caption is not an IPC argument (arguments are process metadata visible to other
// local users): jarvis-say writes it to the private $JARVIS_CACHE/caption and the
// overlay reads that file when `speak` arrives.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // Colours are handed in by jarvis-say from the active Omarchy theme.
    readonly property color accent: Quickshell.env("JARVIS_VIZ_ACCENT") || "#4FC3F7"
    readonly property color glow:   Quickshell.env("JARVIS_VIZ_GLOW")   || "#39A949"
    readonly property color fg:     Quickshell.env("JARVIS_VIZ_FG")     || "#C9D4E0"
    readonly property color bg:     Quickshell.env("JARVIS_VIZ_BG")     || "#0C1B2E"
    readonly property string fontFamily: Quickshell.env("JARVIS_VIZ_FONT") || "JetBrainsMono Nerd Font Propo"
    readonly property int barCount: 28

    property var levels: []
    property real startMs: 0
    property string caption: ""
    property bool speaking: false
    property real level: 0          // current smoothed loudness 0..1
    property var bars: []           // per-bar smoothed heights
    property real phase: 0          // slow rotation for the reactor rings

    // Trust boundary: the caption is agent-generated speech and the envelope comes from
    // whoever calls the IPC. Both are bounded here before anything is stored or rendered;
    // the caption is drawn as plain text only (see textFormat below).
    readonly property int captionMax: 400       // chars; the caption shows at most two elided lines
    readonly property string captionPath: (Quickshell.env("JARVIS_CACHE") || "") + "/caption"

    FileView {
        id: captionFile
        path: root.captionPath
        printErrors: false
        onLoaded: root.caption = String(text() || "").slice(0, root.captionMax)
        onLoadFailed: root.caption = ""
    }
    readonly property int envMaxChars: 65536    // ~10 min at 20 levels/s, "0.00," each
    readonly property int envMaxLevels: 12000

    function parseEnvelope(env) {
        if (typeof env !== "string" || env.length === 0 || env.length > root.envMaxChars) return [];
        const parts = env.split(",", root.envMaxLevels);
        const out = [];
        for (let i = 0; i < parts.length; i++) {
            const v = Number(parts[i]);
            out.push(Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0);
        }
        return out;
    }

    IpcHandler {
        target: "viz"
        function speak(env: string): void {
            captionFile.reload();
            root.levels = root.parseEnvelope(env);
            root.startMs = Date.now();
            root.speaking = true;
            hideTimer.stop();
            safety.restart();
            win.visible = true;
        }
        function stop(): void {
            root.speaking = false;
            hideTimer.restart();
        }
    }

    Timer { id: hideTimer; interval: 600; onTriggered: { win.visible = false; root.level = 0; root.bars = []; } }
    Timer { id: safety;    interval: 120000; onTriggered: root.speaking = false }

    Timer {
        // 30 fps animation loop while the overlay is up
        interval: 33; repeat: true; running: win.visible
        onTriggered: {
            let target = 0;
            if (root.speaking && root.levels.length) {
                const i = Math.floor((Date.now() - root.startMs) / 50);
                target = i < root.levels.length ? root.levels[i] : 0;
            }
            root.level += (target - root.level) * (target > root.level ? 0.55 : 0.25);
            root.phase += 0.02 + root.level * 0.05;

            const b = root.bars.length === root.barCount ? root.bars.slice() : new Array(root.barCount).fill(0);
            const t = Date.now() / 1000;
            for (let k = 0; k < root.barCount; k++) {
                // Envelope shaped by a pseudo-spectrum: stronger low "bins", wobble per bar.
                const shape = 0.35 + 0.65 * Math.pow(1 - k / root.barCount, 0.8);
                const wobble = 0.6 + 0.4 * Math.sin(t * (5 + k * 0.9) + k * 1.7);
                const goal = root.level * shape * wobble;
                b[k] += (goal - b[k]) * (goal > b[k] ? 0.6 : 0.3);
            }
            root.bars = b;
            canvas.requestPaint();
        }
    }

    PanelWindow {
        id: win
        visible: false
        color: "transparent"
        anchors.bottom: true
        margins.bottom: 48
        implicitWidth: 720
        implicitHeight: 190
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "jarvis-viz"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}   // fully click-through

        // Backdrop pill
        Rectangle {
            anchors.fill: parent
            radius: 22
            color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, 0.82)
            border.width: 1
            border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)
        }

        Canvas {
            id: canvas
            anchors.fill: parent
            renderStrategy: Canvas.Cooperative
            onPaint: {
                const ctx = getContext("2d");
                const w = width, h = height;
                ctx.clearRect(0, 0, w, h);
                const cx = w / 2, cy = 74;
                const lv = root.level;
                const a = root.accent, g = root.glow;
                const rgba = (c, al) => `rgba(${Math.round(c.r*255)},${Math.round(c.g*255)},${Math.round(c.b*255)},${al})`;

                // ---- bars, mirrored outwards from the core ----
                const n = root.barCount, bw = 6, gap = 4, start = 62;
                for (let k = 0; k < n; k++) {
                    const bh = 4 + (root.bars[k] || 0) * 54;
                    const x = start + k * (bw + gap);
                    const alpha = 0.25 + 0.75 * (root.bars[k] || 0);
                    ctx.fillStyle = rgba(a, alpha);
                    // right side
                    roundRect(ctx, cx + x, cy - bh / 2, bw, bh, 3);
                    // left side
                    roundRect(ctx, cx - x - bw, cy - bh / 2, bw, bh, 3);
                }

                // ---- arc reactor core ----
                // outer glow
                const grad = ctx.createRadialGradient(cx, cy, 6, cx, cy, 52 + lv * 14);
                grad.addColorStop(0, rgba(a, 0.55 + lv * 0.4));
                grad.addColorStop(0.5, rgba(a, 0.10 + lv * 0.15));
                grad.addColorStop(1, rgba(a, 0));
                ctx.fillStyle = grad;
                ctx.beginPath(); ctx.arc(cx, cy, 52 + lv * 14, 0, Math.PI * 2); ctx.fill();

                // rotating tick ring
                ctx.save(); ctx.translate(cx, cy); ctx.rotate(root.phase);
                ctx.strokeStyle = rgba(a, 0.85); ctx.lineWidth = 2;
                for (let i = 0; i < 24; i++) {
                    const ang = i * Math.PI / 12;
                    const r1 = 34, r2 = i % 3 === 0 ? 42 : 38;
                    ctx.beginPath();
                    ctx.moveTo(Math.cos(ang) * r1, Math.sin(ang) * r1);
                    ctx.lineTo(Math.cos(ang) * r2, Math.sin(ang) * r2);
                    ctx.stroke();
                }
                ctx.restore();

                // counter-rotating arc segments (theme glow colour)
                ctx.save(); ctx.translate(cx, cy); ctx.rotate(-root.phase * 1.6);
                ctx.strokeStyle = rgba(g, 0.9); ctx.lineWidth = 3;
                for (let i = 0; i < 3; i++) {
                    ctx.beginPath(); ctx.arc(0, 0, 28, i * 2.094, i * 2.094 + 1.3); ctx.stroke();
                }
                ctx.restore();

                // core
                const core = ctx.createRadialGradient(cx, cy, 0, cx, cy, 20);
                core.addColorStop(0, "rgba(255,255,255," + (0.85 + lv * 0.15) + ")");
                core.addColorStop(0.35, rgba(a, 0.95));
                core.addColorStop(1, rgba(a, 0.2));
                ctx.fillStyle = core;
                ctx.beginPath(); ctx.arc(cx, cy, 14 + lv * 6, 0, Math.PI * 2); ctx.fill();

                function roundRect(c, x, y, w2, h2, r) {
                    c.beginPath();
                    c.moveTo(x + r, y); c.lineTo(x + w2 - r, y); c.quadraticCurveTo(x + w2, y, x + w2, y + r);
                    c.lineTo(x + w2, y + h2 - r); c.quadraticCurveTo(x + w2, y + h2, x + w2 - r, y + h2);
                    c.lineTo(x + r, y + h2); c.quadraticCurveTo(x, y + h2, x, y + h2 - r);
                    c.lineTo(x, y + r); c.quadraticCurveTo(x, y, x + r, y);
                    c.closePath(); c.fill();
                }
            }
        }

        Text {
            id: label
            text: "J.A.R.V.I.S."
            anchors { left: parent.left; top: parent.top; leftMargin: 18; topMargin: 12 }
            font { family: root.fontFamily; pixelSize: 11; letterSpacing: 3; bold: true }
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.8)
        }

        Text {
            text: root.caption
            textFormat: Text.PlainText   // never interpret speech as rich text (no markup, no remote images)
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 18; bottomMargin: 16 }
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font { family: root.fontFamily; pixelSize: 15 }
            color: root.fg
        }
    }
}
