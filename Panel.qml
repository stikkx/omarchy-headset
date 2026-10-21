import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Headset bar widget: one place for Bluetooth headsets and USB gaming
// headsets (SteelSeries Arctis 7 & co.).
//
// The bar icon draws the active headset mode (Hi-Fi, call, LE Audio) of the
// primary headset; click opens the panel, right-click toggles the mode
// (same as the Super+Shift+H hotkey).
//
// All system work happens in bin/headsetctl: pactl/bluetoothctl for
// Bluetooth (the stikkx/headset-mode logic) and Sapd/HeadsetControl for USB
// headsets. This file only renders its JSON and runs its subcommands.
Panel {
  id: root
  moduleName: "stikkx.headset"
  ipcTarget: "stikkx.headset"
  // Extra IPC functions (refresh/toggleMode), so we own the handler.
  manageIpc: false
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --------------------------------------------------------------- state ---

  property var status: Model.parse("")
  property bool loaded: false
  property bool busy: false
  property string lastError: ""

  readonly property var primary: Model.primary(status)
  readonly property string mode: Model.primaryMode(status)
  readonly property int battery: Model.primaryBattery(status)
  readonly property var btDevices: status.bluetooth || []
  readonly property var usbDevices: (status.usb && status.usb.devices) || []

  readonly property string ctl: decodeURIComponent(Qt.resolvedUrl("bin/headsetctl").toString().replace(/^file:\/\//, ""))

  // ------------------------------------------------------------ settings ---

  readonly property int refreshIntervalSec: {
    var n = parseInt(setting("refreshIntervalSec", 10), 10)
    return isFinite(n) ? Math.min(600, Math.max(3, n)) : 10
  }
  readonly property bool reapplyOnConnect: setting("reapplyOnConnect", true) === true
  readonly property int lowBattery: parseInt(setting("lowBatteryPercent", 15), 10) || 15

  // Last values sent to the USB headset. HeadsetControl cannot read most of
  // them back, so we remember them to show the state and re-apply after the
  // headset power-cycles (Arctis forgets sidetone/lights on power-off).
  readonly property var usbState: {
    var v = setting("usb", null)
    return (v && typeof v === "object") ? v : ({})
  }

  function persist(patch) {
    var next = {}
    var cur = root.settings || {}
    for (var k in cur) if (k !== "id") next[k] = cur[k]
    for (var p in patch) next[p] = patch[p]
    if (root.bar && root.bar.shell && root.bar.shell.updateEntryInline)
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function rememberUsb(key, value) {
    var u = {}
    for (var k in root.usbState) u[k] = root.usbState[k]
    u[key] = value
    persist({ usb: u })
  }

  // -------------------------------------------------------------- colors ---

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property bool batteryLow: battery >= 0 && battery <= lowBattery
  readonly property color iconColor: {
    if (mode === "none") return Qt.darker(barForeground, 1.6)
    if (batteryLow) return urgent
    if (mode === "call" || mode === "duplex") return accent
    return barForeground
  }

  // ------------------------------------------------------------- polling ---

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }
  Timer {
    id: soon
    interval: 700
    onTriggered: root.refresh()
  }

  Process {
    id: statusProc
    command: [root.ctl, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  property var _seenUsb: ({})
  function applyStatus(raw) {
    var next = Model.parse(raw)
    // Re-apply remembered USB settings when a headset (re)appears.
    var seen = {}
    var devs = next.usb.devices
    for (var i = 0; i < devs.length; i++) {
      var key = devs[i].id_vendor + ":" + devs[i].id_product
      seen[key] = true
      if (root.loaded && !root._seenUsb[key] && root.reapplyOnConnect) reapplyUsb(devs[i])
    }
    root._seenUsb = seen
    root.status = next
    root.loaded = true
  }

  // ------------------------------------------------------------- actions ---

  Component {
    id: runner
    Process {
      environment: ({ HEADSETCTL_QUIET: "1" })
      stderr: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var t = String(text).trim()
          if (t !== "") root.lastError = t.split("\n").slice(-1)[0]
        }
      }
      onExited: function(code) {
        root.busy = false
        soon.restart()
        destroy()
      }
    }
  }

  function run(args) {
    root.lastError = ""
    root.busy = true
    var p = runner.createObject(root, { command: [root.ctl].concat(args) })
    p.running = true
  }

  function setMode(device, m) { run(["mode", m, device.card]) }
  function toggleMode() { run(["toggle"]) }
  function setProfile(device, profile) { run(["profile", device.card, profile]) }
  function connectBt(device) { run([device.connected ? "disconnect" : "connect", device.mac]) }
  function useSink(name) { run(["default-sink", name]) }
  function setAutoswitch(on) { run(["autoswitch", on ? "on" : "off"]) }

  function usb(device, flag, value, rememberKey) {
    var args = ["usb", "-d", device.id_vendor.replace(/^0x/, "") + ":" + device.id_product.replace(/^0x/, ""), flag]
    if (value !== undefined && value !== null) args.push(String(value))
    run(args)
    if (rememberKey) rememberUsb(rememberKey, value)
  }

  function reapplyUsb(device) {
    var s = root.usbState
    if (s.sidetone !== undefined && Model.hasCap(device, "sidetone")) usb(device, "-s", s.sidetone)
    if (s.lights !== undefined && Model.hasCap(device, "lights")) usb(device, "-l", s.lights)
    if (s.inactive !== undefined && Model.hasCap(device, "inactive_time")) usb(device, "-i", s.inactive)
    if (s.eqPreset !== undefined && Model.hasCap(device, "equalizer_preset")) usb(device, "-p", s.eqPreset)
    if (s.micVolume !== undefined && Model.hasCap(device, "microphone_volume")) usb(device, "--microphone-volume", s.micVolume)
    if (s.muteLed !== undefined && Model.hasCap(device, "microphone_mute_led_brightness")) usb(device, "--microphone-mute-led-brightness", s.muteLed)
  }

  function setupInTerminal(what) {
    Quickshell.execDetached(["omarchy", "launch", "terminal", "bash", "-lc",
      "'" + root.ctl + "' setup " + what + "; echo; read -n1 -rsp 'Press any key to close…'"])
  }

  // ----------------------------------------------------------------- IPC ---

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function toggleMode(): string { root.toggleMode(); return "ok" }
    function mode(): string { return root.mode }
  }

  // ---------------------------------------------------------- bar button ---

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (root.mode === "none") return "No headset connected"
      var name = root.primary.kind === "bt" ? root.primary.device.name : Model.usbName(root.primary.device)
      var t = name + " · " + Model.modeLabel(root.mode)
      if (root.battery >= 0) t += " · " + root.battery + "%"
      return t
    }
    text: Model.modeGlyph(root.mode)
    foreground: root.iconColor
    useActiveColor: false
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleMode()
      else root.toggle()
    }
  }

  // --------------------------------------------------------------- panel ---

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {}
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "m" || t === "M") root.toggleMode()
        else if (t === "r" || t === "R") root.refresh()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: root.mode === "none" ? "No headset"
              : (root.primary.kind === "bt" ? root.primary.device.name : Model.usbName(root.primary.device))
            meta: {
              if (!root.loaded) return "Checking…"
              if (root.mode === "none") return "Connect a Bluetooth headset or plug in a USB dongle"
              var parts = [Model.modeLabel(root.mode)]
              if (root.primary.kind === "bt") {
                var codec = Model.codecOf(root.primary.device.profile)
                if (codec !== "") parts.push(codec)
              } else {
                parts.push("USB")
              }
              if (root.battery >= 0) parts.push(root.battery + "%")
              return parts.join(" · ")
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.mode === "none" ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                text: Model.modeGlyph(root.mode)
                color: root.mode === "none" ? root.dim : (root.batteryLow ? root.urgent : root.accent)
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Button {
                visible: root.mode !== "none"
                text: root.mode === "music" ? "Call" : "Hi-Fi"
                iconText: root.mode === "music" ? "󰋎" : "󰋋"
                tooltipText: "Toggle headset mode (Super+Shift+H)"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.toggleMode()
              }
            }
          }

          Text {
            width: parent.width
            visible: root.lastError !== ""
            textFormat: Text.PlainText
            text: root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------- Bluetooth ---

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "BLUETOOTH"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.btDevices.length === 0
            textFormat: Text.PlainText
            text: root.status.btPowered
              ? "No paired Bluetooth headsets. Pair one from the Bluetooth panel (Super+Ctrl+B)."
              : "Bluetooth is off."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.btDevices

            Column {
              id: btRow
              required property var modelData
              readonly property var dev: modelData
              readonly property bool live: dev.connected && dev.card !== ""
              width: column.width
              spacing: Style.space(8)

              Item {
                width: parent.width
                height: Math.max(btName.implicitHeight + btMeta.implicitHeight, connectBtn.implicitHeight)

                Column {
                  anchors.left: parent.left
                  anchors.right: connectBtn.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    id: btName
                    width: parent.width
                    textFormat: Text.PlainText
                    text: (btRow.dev.icon === "audio-headset" ? "󰋎  " : "󰋋  ") + btRow.dev.name
                    color: btRow.dev.connected ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    id: btMeta
                    width: parent.width
                    textFormat: Text.PlainText
                    text: {
                      if (!btRow.dev.connected) return "Not connected"
                      var p = [Model.modeLabel(btRow.dev.mode)]
                      var c = Model.codecOf(btRow.dev.profile)
                      if (c !== "") p.push(c)
                      if (btRow.dev.battery !== null && btRow.dev.battery !== undefined)
                        p.push(Model.batteryGlyph(btRow.dev.battery, false) + " " + btRow.dev.battery + "%")
                      if (btRow.dev.sink !== "" && btRow.dev.sink === root.status.defaultSink) p.push("default output")
                      return p.join(" · ")
                    }
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Button {
                  id: connectBtn
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: btRow.dev.connected ? "Disconnect" : "Connect"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: root.status.btPowered
                  onClicked: root.connectBt(btRow.dev)
                }
              }

              ButtonGroup {
                visible: btRow.live
                options: Model.modeOptions(btRow.dev)
                value: btRow.dev.mode
                cursorIndex: -1
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onChanged: function(v) { root.setMode(btRow.dev, v) }
              }

              Row {
                visible: btRow.live && btRow.dev.mode === "music" && codecDrop.options.length > 1
                spacing: Style.space(8)
                Dropdown {
                  id: codecDrop
                  width: Style.spacing.dropdownWidth
                  label: "Codec"
                  options: Model.codecOptions(btRow.dev)
                  value: btRow.dev.profile
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.setProfile(btRow.dev, v) }
                }
              }

              Button {
                visible: btRow.live && btRow.dev.sink !== "" && btRow.dev.sink !== root.status.defaultSink
                text: "Use as output"
                iconText: "󰓃"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.useSink(btRow.dev.sink)
              }
            }
          }

          // ------------------------------------------------------- USB ---

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "USB HEADSET"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.usbDevices.length === 0
            textFormat: Text.PlainText
            text: root.status.headsetcontrol
              ? "No supported USB headset found. Is the dongle plugged in and the headset on?"
              : "HeadsetControl is not installed — it unlocks battery, sidetone, lights, ChatMix and more for SteelSeries Arctis, Logitech, Corsair and HyperX headsets."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            visible: !root.status.headsetcontrol && root.loaded
            text: "Install HeadsetControl"
            iconText: "󰏗"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setupInTerminal("usb")
          }

          Repeater {
            model: root.usbDevices

            Column {
              id: usbRow
              required property var modelData
              readonly property var dev: modelData
              readonly property var bat: Model.usbBattery(dev)
              readonly property int mix: Model.chatmix(dev)
              width: column.width
              spacing: Style.space(10)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "󰋎  " + Model.usbName(usbRow.dev)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: {
                  if (!Model.hasCap(usbRow.dev, "battery_status") && !Model.hasCap(usbRow.dev, "battery")) return "Connected"
                  if (!usbRow.bat.available) return "Headset off or out of range"
                  return Model.batteryGlyph(usbRow.bat.level, usbRow.bat.charging) + "  " + usbRow.bat.level + "%" + (usbRow.bat.charging ? " · charging" : "")
                }
                color: usbRow.bat.available && usbRow.bat.level >= 0 && usbRow.bat.level <= root.lowBattery ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              // Game / Chat output channel (Arctis exposes two sinks).
              Column {
                visible: chanGroup.options.length > 1
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "Output channel"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                ButtonGroup {
                  id: chanGroup
                  options: Model.channelOptions(usbRow.dev)
                  value: root.status.defaultSink
                  cursorIndex: -1
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.useSink(v) }
                }
              }

              // ChatMix is a hardware dial; we only display it.
              Column {
                visible: usbRow.mix >= 0
                width: parent.width
                spacing: Style.space(4)
                Item {
                  width: parent.width
                  height: gameLbl.implicitHeight
                  Text { id: gameLbl; text: "Game"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { anchors.horizontalCenter: parent.horizontalCenter; text: "ChatMix"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                  Text { anchors.right: parent.right; text: "Chat"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
                }
                Rectangle {
                  width: parent.width
                  height: Math.max(4, Style.space(4))
                  radius: Style.cornerRadius > 0 ? height / 2 : 0
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                  Rectangle {
                    width: Math.max(4, Style.space(6))
                    height: parent.height * 2.4
                    radius: Style.cornerRadius > 0 ? width / 2 : 0
                    anchors.verticalCenter: parent.verticalCenter
                    x: (parent.width - width) * Math.max(0, Math.min(1, usbRow.mix / 128))
                    color: root.accent
                  }
                }
              }

              Column {
                visible: Model.hasCap(usbRow.dev, "sidetone")
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "Sidetone · hear your own voice" + (root.usbState.sidetone !== undefined ? "  (" + Math.round(root.usbState.sidetone / 1.28) + "%)" : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                PanelSlider {
                  bar: root.bar
                  width: parent.width
                  minimum: 0
                  maximum: 128
                  step: 8
                  integer: true
                  value: root.usbState.sidetone !== undefined ? root.usbState.sidetone : 0
                  onReleased: function(v) { root.usb(usbRow.dev, "-s", Math.round(v), "sidetone") }
                }
              }

              Column {
                visible: Model.hasCap(usbRow.dev, "inactive_time")
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "Auto power-off"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                ButtonGroup {
                  options: [{ value: "0", label: "Never" }, { value: "10", label: "10m" }, { value: "30", label: "30m" }, { value: "60", label: "1h" }, { value: "90", label: "90m" }]
                  value: root.usbState.inactive !== undefined ? String(root.usbState.inactive) : ""
                  cursorIndex: -1
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.usb(usbRow.dev, "-i", parseInt(v, 10), "inactive") }
                }
              }

              Column {
                visible: Model.hasCap(usbRow.dev, "equalizer_preset")
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "Equalizer preset"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                ButtonGroup {
                  options: ["0", "1", "2", "3"].map(function(v) { return { value: v, label: "Preset " + (parseInt(v, 10) + 1) } })
                  value: root.usbState.eqPreset !== undefined ? String(root.usbState.eqPreset) : ""
                  cursorIndex: -1
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.usb(usbRow.dev, "-p", parseInt(v, 10), "eqPreset") }
                }
              }

              Column {
                visible: Model.hasCap(usbRow.dev, "microphone_volume")
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "Microphone volume"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                PanelSlider {
                  bar: root.bar
                  width: parent.width
                  minimum: 0
                  maximum: 128
                  step: 8
                  integer: true
                  value: root.usbState.micVolume !== undefined ? root.usbState.micVolume : 128
                  onReleased: function(v) { root.usb(usbRow.dev, "--microphone-volume", Math.round(v), "micVolume") }
                }
              }

              Column {
                visible: Model.hasCap(usbRow.dev, "microphone_mute_led_brightness")
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "Mic mute LED"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                ButtonGroup {
                  options: [{ value: "0", label: "Off" }, { value: "1", label: "Low" }, { value: "2", label: "Medium" }, { value: "3", label: "High" }]
                  value: root.usbState.muteLed !== undefined ? String(root.usbState.muteLed) : ""
                  cursorIndex: -1
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onChanged: function(v) { root.usb(usbRow.dev, "--microphone-mute-led-brightness", parseInt(v, 10), "muteLed") }
                }
              }

              Column {
                visible: Model.hasCap(usbRow.dev, "bt_call_volume")
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "Bluetooth call volume" + (root.usbState.btCallVolume !== undefined ? "  (" + root.usbState.btCallVolume + "%)" : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                PanelSlider {
                  bar: root.bar
                  width: parent.width
                  minimum: 0
                  maximum: 100
                  step: 5
                  integer: true
                  value: root.usbState.btCallVolume !== undefined ? root.usbState.btCallVolume : 100
                  onReleased: function(v) { root.usb(usbRow.dev, "--bt-call-volume", Math.round(v), "btCallVolume") }
                }
              }

              Toggle {
                visible: Model.hasCap(usbRow.dev, "lights")
                width: parent.width
                label: "Lights"
                description: "RGB / status lighting on the ear cups"
                checked: root.usbState.lights !== 0
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.usb(usbRow.dev, "-l", checked ? 0 : 1, "lights")
              }

              Toggle {
                visible: Model.hasCap(usbRow.dev, "voice_prompts")
                width: parent.width
                label: "Voice prompts"
                checked: root.usbState.voicePrompts !== 0
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.usb(usbRow.dev, "-v", checked ? 0 : 1, "voicePrompts")
              }

              Toggle {
                visible: Model.hasCap(usbRow.dev, "rotate_to_mute")
                width: parent.width
                label: "Rotate to mute"
                description: "Mute by flipping the mic boom up"
                checked: root.usbState.rotateToMute !== 0
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.usb(usbRow.dev, "-r", checked ? 0 : 1, "rotateToMute")
              }

              Toggle {
                visible: Model.hasCap(usbRow.dev, "volume_limiter")
                width: parent.width
                label: "Volume limiter"
                checked: root.usbState.volumeLimiter === 1
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.usb(usbRow.dev, "--volume-limiter", checked ? 0 : 1, "volumeLimiter")
              }

              Toggle {
                visible: Model.hasCap(usbRow.dev, "bt_when_powered_on")
                width: parent.width
                label: "Bluetooth on at power-on"
                checked: root.usbState.btOnPower === 1
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.usb(usbRow.dev, "--bt-when-powered-on", checked ? 0 : 1, "btOnPower")
              }
            }
          }

          // -------------------------------------------------- Settings ---

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            text: "SETTINGS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Toggle {
            width: parent.width
            label: "Auto call mode"
            description: "Switch Bluetooth headsets to call mode whenever an app opens the mic. Off keeps Hi-Fi until you switch."
            checked: root.status.autoswitch === true
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.setAutoswitch(!checked)
          }

          Toggle {
            width: parent.width
            label: "Restore USB settings"
            description: "Re-send sidetone, lights, power-off timer and EQ when the headset turns on."
            checked: root.reapplyOnConnect
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onClicked: root.persist({ reapplyOnConnect: !checked })
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Super+Shift+H or right-click toggles Hi-Fi ⇄ Call (Game ⇄ Chat on USB headsets).  Keys here: m mode · r refresh"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)
            Button {
              text: "Bluetooth audio tweaks"
              tooltipText: "Enable mSBC calls and SBC-XQ, disable silent HFP auto-switch (WirePlumber)"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.setupInTerminal("bt")
            }
            Button {
              visible: root.status.leAudioSetup === true
              text: "LE Audio setup"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: Quickshell.execDetached(["omarchy", "launch", "terminal", "le-audio-setup"])
            }
            Button {
              text: "Refresh"
              iconText: "󰑐"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }
        }
      }
    }
  }
}
