import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Automatic screen lock that follows the network you are on.
//
// Omarchy already owns the switch: a flag file at
// ~/.local/state/omarchy/indicators/stay-awake, watched by the built-in idle
// service. Present means the screen never locks on its own. `omarchy toggle
// idle` flips it, the built-in coffee-cup indicator flips it, and so does this
// widget -- they all agree because they all read and write that one file.
//
// What this adds is the policy. Networks you call home live in
// ~/.config/omarchy-autolock/config as `home=<connection-uuid>` lines. Joining
// a network applies that network's setting: home stays awake, anything else --
// including no network at all -- locks on the usual idle timeout. A toggle from
// here or from the built-in indicator overrides the current network until you
// switch networks again, so "just stay awake for this one meeting" costs one
// click and expires by itself.
//
// Away is applied only after the same non-home network has been seen twice in a
// row; home is applied immediately. A Wi-Fi blip on the way to the kitchen
// should not quietly re-arm the lock, but arriving somewhere new should arm it
// without waiting.
Panel {
  id: root
  moduleName: "dbarke.autolock"
  ipcTarget: "dbarke.autolock"
  manageIpc: false

  // ---------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- settings
  readonly property int intervalMs: Math.max(2, Number(setting("refreshIntervalSec", 10))) * 1000
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy-autolock/config"
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/indicators"
  readonly property string statePath: stateDir + "/stay-awake"
  readonly property string shellConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"

  // ---------------------------------------------------------------- state
  property bool ready: false
  property bool stayAwake: false          // the flag file exists -- no automatic lock
  property var net: null                  // { uuid, type, name } of the active connection
  property var homes: []                  // connection uuids treated as home
  property int lockSeconds: 300           // idle.lock from shell.json (the shell's own default)
  property bool busy: false
  property string lastError: ""

  // Which network the policy was last applied for, so a manual override sticks
  // until the network actually changes.
  property string appliedFor: ""
  property string pendingKey: ""
  property int pendingSightings: 0
  property bool forceApply: false

  readonly property string netKey: net ? net.uuid : "none"
  readonly property bool isHome: !!net && homes.indexOf(net.uuid) >= 0
  readonly property bool overridden: ready && appliedFor === netKey && stayAwake !== isHome
  readonly property int lockMinutes: Math.max(1, Math.round(lockSeconds / 60))
  readonly property string netLabel: {
    if (!net) return "No network"
    return net.name + (net.type === "802-3-ethernet" ? " (wired)" : "")
  }

  // ------------------------------------------------------------- reading
  function refreshNow() {
    if (!pollProc.running) pollProc.running = true
  }

  // One process, sections split by marker lines, so a poll is one spawn.
  function applyOutput(text) {
    var sections = ({})
    var current = "net"
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var marker = lines[i].match(/^@@(\w+)$/)
      if (marker) { current = marker[1]; continue }
      if (!sections[current]) sections[current] = []
      sections[current].push(lines[i])
    }

    // nmcli -t escapes ":" inside fields as "\:". Wi-Fi wins over a wired link,
    // so a laptop docked at home is still identified by the network it joined.
    var wifi = null
    var wired = null
    var active = sections.net || []
    for (var a = 0; a < active.length; a++) {
      var fields = active[a].replace(/\\:/g, "\u0001").split(":")
      if (fields.length < 3) continue
      var entry = {
        uuid: fields[0].toLowerCase(),
        type: fields[1],
        name: fields.slice(2).join(":").replace(/\u0001/g, ":")
      }
      if (entry.type === "802-11-wireless") { if (!wifi) wifi = entry }
      else if (entry.type === "802-3-ethernet") { if (!wired) wired = entry }
    }
    net = wifi || wired

    var nextHomes = []
    var conf = sections.conf || []
    for (var c = 0; c < conf.length; c++) {
      var home = conf[c].match(/^home=([0-9a-fA-F-]{36})\b/)
      if (home) nextHomes.push(home[1].toLowerCase())
    }
    homes = nextHomes

    stayAwake = (sections.awake || []).join("").trim() === "yes"
    ready = true
    evaluatePolicy()
  }

  function readLockSeconds() {
    var parsed = 0
    try {
      var conf = JSON.parse(shellConfigView.text())
      if (conf && conf.idle) parsed = Number(conf.idle.lock)
    } catch (error) {
      parsed = 0
    }
    lockSeconds = isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : 300
  }

  // -------------------------------------------------------------- policy
  function evaluatePolicy() {
    if (!ready || busy) return

    if (forceApply) { applyPolicy(); return }

    // Same network as last time: whatever the flag says now stands, including a
    // manual override from this widget or the built-in indicator.
    if (netKey === appliedFor) {
      pendingKey = ""
      pendingSightings = 0
      return
    }

    if (isHome) { applyPolicy(); return }

    if (pendingKey !== netKey) {
      pendingKey = netKey
      pendingSightings = 1
      return
    }

    pendingSightings += 1
    if (pendingSightings >= 2) applyPolicy()
  }

  function applyPolicy() {
    appliedFor = netKey
    pendingKey = ""
    pendingSightings = 0
    forceApply = false
    if (stayAwake !== isHome) setStayAwake(isHome)
  }

  // ------------------------------------------------------------- actions
  // Every action is argv to bash with values passed as positional parameters,
  // never spliced into the script text.
  function run(script, args) {
    if (busy) return
    busy = true
    lastError = ""
    actionProc.command = ["bash", "-c", script, "autolock-widget"].concat(args || [])
    actionProc.running = true
  }

  // omarchy-toggle-idle owns the flag file; going through it keeps this widget,
  // the CLI, and the built-in indicator on one code path.
  function setStayAwake(value) {
    run('omarchy-toggle-idle "$1" >/dev/null', [value ? "stay-awake" : "allow-idle"])
  }

  // A manual flip claims the current network, so the policy does not undo it on
  // the next poll. The claim dies when you join a different network.
  function toggleStayAwake() {
    appliedFor = netKey
    pendingKey = ""
    pendingSightings = 0
    setStayAwake(!stayAwake)
  }

  function toggleHome() {
    if (!net) return
    var uuid = String(net.uuid).toLowerCase()
    if (!/^[0-9a-f-]{36}$/.test(uuid)) return

    forceApply = true
    if (isHome) {
      run('sed -i "/^home=$1\\b/Id" "$2"', [uuid, configPath])
    } else {
      run('mkdir -p "$(dirname "$2")"; [ -f "$2" ] || : > "$2"; '
          + 'printf "home=%s  # %s\\n" "$1" "$3" >> "$2"',
          [uuid, configPath, String(net.name).replace(/[\r\n]/g, " ")])
    }
  }

  // ------------------------------------------------------------------ bar
  readonly property string barGlyph: stayAwake ? "󰅶" : "󰌾"

  readonly property string statusTitle: {
    if (!ready) return "Checking…"
    if (busy) return "Applying…"
    return stayAwake ? "Screen stays awake" : "Locks after " + lockMinutes + " min idle"
  }

  readonly property string statusDetail: {
    if (!ready) return ""
    if (!net) return "No network — the lock stays on."
    return netLabel + (isHome ? " · home" : " · not home")
  }

  readonly property string barTooltip: {
    var lines = [statusTitle]
    if (statusDetail !== "") lines.push(statusDetail)
    if (overridden) lines.push("Overridden until you switch networks.")
    return lines.join("\n")
  }

  // --------------------------------------------------------------- wiring
  Timer {
    interval: root.opened ? 2000 : root.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  Process {
    id: pollProc
    running: false
    command: ["bash", "-c",
      'echo @@net; nmcli -t -f UUID,TYPE,NAME connection show --active 2>/dev/null; '
      + 'echo @@conf; cat "$1" 2>/dev/null; '
      + 'echo @@awake; [ -f "$2" ] && echo yes; true',
      "autolock-widget", root.configPath, root.statePath]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }
  }

  Process {
    id: actionProc
    running: false

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") root.lastError = message
      }
    }

    onExited: function (exitCode) {
      root.busy = false
      if (exitCode === 0) root.lastError = ""
      root.refreshNow()
    }
  }

  // The idle service writes the flag file too, and so does `omarchy toggle
  // idle`. Watching the directory keeps this widget honest without polling
  // faster than the network check needs.
  FileView {
    path: root.stateDir
    watchChanges: true
    printErrors: false
    onFileChanged: root.refreshNow()
  }

  FileView {
    id: shellConfigView
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.readLockSeconds()
    onFileChanged: reload()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function stayAwake(): void { root.setStayAwake(true) }
    function allowLock(): void { root.setStayAwake(false) }
    function toggleLock(): void { root.toggleStayAwake() }
    function status(): string {
      return JSON.stringify({ stayAwake: root.stayAwake, network: root.net, home: root.isHome,
                              overridden: root.overridden, lockSeconds: root.lockSeconds,
                              appliedFor: root.appliedFor, homes: root.homes })
    }
  }

  onOpenedChanged: if (opened) {
    refreshNow()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    active: root.stayAwake
    dimmed: root.ready && !root.stayAwake
    tooltipText: root.opened ? "" : root.barTooltip

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleStayAwake()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onActivateRequested: root.toggleStayAwake()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = t.toLowerCase()
        if (key === "a") root.toggleStayAwake()
        else if (key === "h" && root.net) root.toggleHome()
        else if (key === "r") root.refreshNow()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelSectionHeader {
          width: parent.width
          text: "AUTO-LOCK"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.statusTitle
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          Text {
            width: parent.width
            visible: text !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.statusDetail
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Toggle {
          width: parent.width
          label: "Lock the screen automatically"
          description: root.stayAwake
            ? "Off: the screen stays on until you lock it yourself."
            : "On: locks after " + root.lockMinutes + " min idle."
          checked: !root.stayAwake
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (!root.busy) root.toggleStayAwake()
        }

        Text {
          width: parent.width
          visible: root.overridden
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "Overriding this network. It goes back to "
            + (root.isHome ? "staying awake" : "locking") + " when you switch networks."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width }

        PanelSectionHeader {
          width: parent.width
          text: "NETWORK · " + root.netLabel.toUpperCase()
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Toggle {
          width: parent.width
          visible: !!root.net
          label: "Treat this network as home"
          description: root.isHome
            ? "The screen stays awake whenever you join it."
            : "Off: joining it arms the lock, like anywhere else."
          checked: root.isHome
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: if (!root.busy) root.toggleHome()
        }

        Text {
          width: parent.width
          visible: !root.net
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "Nothing is connected, so there is no network to mark. The lock stays on."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.homes.length > 0
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.homes.length === 1 ? "1 network marked as home." : root.homes.length + " networks marked as home."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          visible: root.lastError !== ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "Enter/a auto-lock" + (root.net ? " · h home" : "") + " · r refresh"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
