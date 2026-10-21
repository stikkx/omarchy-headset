// Model.js — pure helpers over the `headsetctl status` JSON.
//
// Every function degrades to a sane fallback: the status can be empty
// (backend still starting), a headset can vanish mid-poll, and
// HeadsetControl may be missing entirely.

.pragma library

function parse(raw) {
  var empty = { bluetooth: [], usb: { installed: false, devices: [] }, defaultSink: "", defaultSource: "", autoswitch: true, btPowered: false, headsetcontrol: false, leAudioSetup: false }
  try {
    var s = JSON.parse(String(raw || ""))
    if (!s || typeof s !== "object") return empty
    if (!Array.isArray(s.bluetooth)) s.bluetooth = []
    if (!s.usb || !Array.isArray(s.usb.devices)) s.usb = { installed: !!(s.usb && s.usb.installed), devices: [] }
    return s
  } catch (e) {
    return empty
  }
}

// ------------------------------------------------------------ primary ---

// The headset the bar icon (and the hotkey) talk about: a connected
// Bluetooth headset with an audio card wins, then a USB headset.
function primary(status) {
  var bt = status.bluetooth || []
  for (var i = 0; i < bt.length; i++) {
    if (bt[i].connected && bt[i].card) return { kind: "bt", device: bt[i] }
  }
  var usb = (status.usb && status.usb.devices) || []
  if (usb.length > 0) return { kind: "usb", device: usb[0] }
  return { kind: "none", device: null }
}

// music | call | duplex | off | none — what the bar icon draws.
function primaryMode(status) {
  var p = primary(status)
  if (p.kind === "bt") return p.device.mode || "off"
  if (p.kind === "usb") return isChatSink(status.defaultSink) ? "call" : "music"
  return "none"
}

function primaryBattery(status) {
  var p = primary(status)
  if (p.kind === "bt") return p.device.battery === null || p.device.battery === undefined ? -1 : p.device.battery
  if (p.kind === "usb") return usbBattery(p.device).level
  return -1
}

// ---------------------------------------------------------- bluetooth ---

function modeLabel(mode) {
  switch (mode) {
    case "music": return "Hi-Fi"
    case "call": return "Call"
    case "duplex": return "LE Audio"
    case "off": return "Audio off"
    default: return "Disconnected"
  }
}

function modeDetail(mode) {
  switch (mode) {
    case "music": return "Stereo playback · internal mic"
    case "call": return "Headset mic · mono 16 kHz"
    case "duplex": return "Stereo + headset mic (LC3)"
    case "off": return "Connected, no audio profile"
    default: return ""
  }
}

function codecOf(profile) {
  var p = String(profile || "")
  if (p.indexOf("a2dp-sink") !== 0) {
    if (p.indexOf("headset-head-unit") === 0) return p.indexOf("cvsd") >= 0 ? "CVSD" : "mSBC"
    if (p.indexOf("bap") === 0) return "LC3"
    return ""
  }
  var c = p.replace(/^a2dp-sink-?/, "").replace(/_duplex$/, "")
  return (c === "" ? "sbc" : c).toUpperCase().replace(/_/g, " ")
}

function hasProfile(device, name) {
  var ps = device.profiles || []
  for (var i = 0; i < ps.length; i++) if (ps[i].name === name) return true
  return false
}

function modeOptions(device) {
  var opts = [{ value: "music", label: "Hi-Fi" }, { value: "call", label: "Call" }]
  if (hasProfile(device, "bap-duplex")) opts.push({ value: "duplex", label: "LE Audio" })
  opts.push({ value: "off", label: "Off" })
  return opts
}

function codecOptions(device) {
  var out = []
  var ps = device.profiles || []
  for (var i = 0; i < ps.length; i++) {
    if (ps[i].name.indexOf("a2dp-sink") === 0) out.push({ value: ps[i].name, label: codecOf(ps[i].name) })
  }
  return out
}

// ---------------------------------------------------------------- usb ---

// Capability check that tolerates both `capabilities` (CAP_LIGHTS) and
// `capabilities_str` ("lights") spellings across HeadsetControl versions.
// HeadsetControl spells some capabilities differently in the two lists
// (CAP_BT_WHEN_POWERED_ON vs "bluetooth when powered on").
var CAP_ALIASES = {
  bt_when_powered_on: "bluetooth_when_powered_on",
  bt_call_volume: "bluetooth_call_volume"
}

function hasCap(device, cap) {
  var c = String(cap).toLowerCase()
  if (CAP_ALIASES[c] && hasCap(device, CAP_ALIASES[c])) return true
  var a = (device && device.capabilities) || []
  var b = (device && device.capabilities_str) || []
  for (var i = 0; i < a.length; i++) if (String(a[i]).toLowerCase() === "cap_" + c) return true
  var spaced = c.replace(/_/g, " ")
  for (var j = 0; j < b.length; j++) {
    var s = String(b[j]).toLowerCase()
    if (s === c || s === spaced) return true
  }
  return false
}

function usbBattery(device) {
  var b = device && device.battery
  if (!b || typeof b !== "object") return { level: -1, charging: false, available: false }
  var st = String(b.status || "")
  return {
    level: typeof b.level === "number" ? b.level : -1,
    charging: st === "BATTERY_CHARGING",
    available: st === "BATTERY_AVAILABLE" || st === "BATTERY_CHARGING"
  }
}

// HeadsetControl reports chatmix as a number (0 = full game, 128 = full
// chat, 64 = balanced) or, in some versions, an object with a level.
function chatmix(device) {
  var c = device ? device.chatmix : undefined
  if (typeof c === "number") return c
  if (c && typeof c === "object" && typeof c.level === "number") return c.level
  return -1
}

function isChatSink(name) {
  return /chat/i.test(String(name || ""))
}

function channelOptions(device) {
  var out = []
  var sinks = (device && device.sinks) || []
  for (var i = 0; i < sinks.length; i++) {
    var label = isChatSink(sinks[i].name) ? "Chat" : (/game|analog-stereo/i.test(sinks[i].name) ? "Game" : sinks[i].description)
    out.push({ value: sinks[i].name, label: label })
  }
  return out
}

function usbName(device) {
  return String((device && device.device) || "USB headset").replace(/\s*\(.*\)\s*$/, "")
}

// ------------------------------------------------------------- glyphs ---

function batteryGlyph(level, charging) {
  if (level < 0) return ""
  if (charging) return "󰂄"
  var g = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  return g[Math.max(0, Math.min(10, Math.round(level / 10)))]
}

// Nerd Font glyph per mode — the same icon font as the rest of the bar.
function modeGlyph(mode) {
  switch (mode) {
    case "call": return "󰋎"    // headset with boom mic
    case "duplex": return "󰥰"  // bluetooth headphones (LE Audio)
    case "off": return "󰟎"     // headphones off
    case "none": return "󰟎"
    default: return "󰋋"        // headphones
  }
}
