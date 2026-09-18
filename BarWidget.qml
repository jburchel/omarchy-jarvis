// Jarvis bar widget — shows what the voice assistant is doing and gives
// one-click control. Agent-agnostic: it only reads Jarvis's state file and
// runs the `jarvis` CLI, so it works for whichever LLM tool is speaking.
//
//   left click    mute / unmute
//   right click   hush (stop speaking now, drop the queue)
//   middle click  wake word on / off
//   wheel         (unused)
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.jburchel.jarvis"

  // idle | speaking | listening | muted | off   — written by bin/jarvis-env's jarvis_state.
  property string state: "idle"
  property string wakeActive: "unknown"   // active | inactive | unknown

  // $XDG_RUNTIME_DIR/jarvis-<uid>/state; the uid is the last path segment of the runtime dir.
  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000"
  readonly property string uid: {
    const m = runtimeDir.match(/(\d+)\/?$/)
    return m ? m[1] : "1000"
  }
  readonly property string statePath: (Quickshell.env("JARVIS_CACHE") || (runtimeDir + "/jarvis-" + uid)) + "/state"

  readonly property string glyph: {
    switch (state) {
      case "speaking":  return "󰕾"
      case "listening": return "󰍬"
      case "muted":     return "󰖁"
      case "off":       return "󰋏"
      default:          return "󰋎"
    }
  }
  readonly property string tip: {
    const wake = wakeActive === "active" ? "  ·  wake word on" : (wakeActive === "inactive" ? "  ·  wake word off" : "")
    switch (state) {
      case "speaking":  return "Jarvis is speaking — right-click to hush" + wake
      case "listening": return "Jarvis is listening" + wake
      case "muted":     return "Jarvis muted — click to unmute" + wake
      case "off":       return "Jarvis off" + wake
      default:          return "Jarvis idle — click to mute" + wake
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function run(cmd) { if (root.bar) root.bar.run(cmd) }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.state = String(text() || "idle").trim() || "idle"
    onLoadFailed: root.state = "idle"
  }

  // The state file is replaced atomically (write tmp + mv), which some watchers
  // miss; a slow poll keeps the icon honest either way.
  Timer { interval: 2000; repeat: true; running: true; onTriggered: stateFile.reload() }

  Process {
    id: wakeProbe
    command: ["systemctl", "--user", "is-active", "jarvis-listen.service"]
    stdout: StdioCollector { onStreamFinished: root.wakeActive = String(text).trim() === "active" ? "active" : "inactive" }
  }
  Timer { interval: 15000; repeat: true; running: true; triggeredOnStart: true; onTriggered: wakeProbe.running = true }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    active: root.state === "speaking" || root.state === "listening"
    tooltipText: root.tip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.run("jarvis hush")
      else if (b === Qt.MiddleButton) root.run(root.wakeActive === "active" ? "jarvis listen stop" : "jarvis listen start")
      else root.run("jarvis toggle-mute")
    }
  }
}
