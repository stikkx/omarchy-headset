# stikkx.headset: Headset Mode for Omarchy

A bar widget for the Omarchy shell that controls your Bluetooth headsets and
USB gaming headsets (such as the SteelSeries Arctis 7) in one place. It uses
the shell's own UI kit, so it follows whichever Omarchy theme is active.

It brings together two projects:

- [stikkx/headset-mode](https://github.com/stikkx/headset-mode) switches a
  Bluetooth headset between Hi-Fi music (A2DP with the best available codec)
  and calls (HFP with the headset mic). It also supports LE Audio duplex.
- [Sapd/HeadsetControl](https://github.com/Sapd/HeadsetControl) talks to USB
  headsets for battery, sidetone, lights, ChatMix, power-off timer, EQ and
  more.

## Bar icon

The icon shows the current mode of the active headset:

| Icon | Meaning |
|------|---------|
| 󰋋 | Hi-Fi / music (on USB: Game channel) |
| 󰋎 in the accent color | Call mode, headset mic active (on USB: Chat channel) |
| 󰥰 in the accent color | LE Audio duplex (stereo and mic at once) |
| 󰟎 | Profile off, or dimmed when no headset is connected |
| red | Battery is low |

Left-click opens the panel. Right-click toggles the mode. The tooltip shows
the device name, mode and battery level.

## Hotkeys

| Key | Action |
|-----|--------|
| `Super+Shift+H` | Toggle Hi-Fi and Call. With only a USB headset connected, it toggles the Game and Chat channels instead. |
| `Super+Ctrl+Shift+H` | Open or close the panel |
| `m` / `r` in the panel | Toggle mode / refresh |

## Panel

**Bluetooth**, for each paired headset:
- connect or disconnect
- battery level
- mode: Hi-Fi, Call, LE Audio or Off
- codec picker (LDAC, aptX HD, AAC, SBC-XQ…)
- "Use as output"

**USB headset**, showing only the controls your headset supports:
- battery and charging state
- Game/Chat channel
- ChatMix dial position
- sidetone, auto power-off, EQ preset, mic volume
- lights, voice prompts, rotate-to-mute, volume limiter

**Settings**:
- WirePlumber auto-switch to call mode
- restore USB settings when the headset powers on (the Arctis forgets
  sidetone and lights)
- one-click setup helpers

## Install

```bash
omarchy plugin add https://github.com/stikkx/omarchy-headset --enable
omarchy restart shell        # the first install of a new plugin needs one restart
```

Optional extras. Nothing here changes your config unless you run it:

```bash
cd ~/.config/omarchy/plugins/stikkx.headset
./install.sh            # link the `headsetctl` CLI into ~/.local/bin
./install.sh --hotkey   # ...and add the hotkeys to ~/.config/hypr/bindings.lua (backed up first)

headsetctl setup usb    # HeadsetControl + udev rules (needed for SteelSeries etc.; uses sudo)
headsetctl setup bt     # optional: mSBC/SBC-XQ, no silent HFP switching (backs up an existing file)
```

## Remove

```bash
~/.config/omarchy/plugins/stikkx.headset/install.sh --uninstall   # hotkeys + CLI link
omarchy plugin remove stikkx.headset
```

`headsetctl setup` leaves behind two things that you can delete by hand:
`/etc/udev/rules.d/70-headsets.rules` and
`~/.config/wireplumber/wireplumber.conf.d/50-bluez.conf`.

## Dependencies

- **Required:** PipeWire with `pactl`, WirePlumber 0.5+ (`wpctl`), BlueZ
  (`bluetoothctl`) and `jq`. Omarchy ships all of them.
- **Optional:** [HeadsetControl](https://github.com/Sapd/HeadsetControl)
  (`headsetcontrol`, in Arch `extra`) for USB headset controls.
  `le-audio-setup` from
  [headset-mode](https://github.com/stikkx/headset-mode) adds LE Audio
  pairing.

## Development

Work in a checkout outside `~/.config`, then run `./install.sh` to copy the
files into place. The shell hot-reloads them. The plugin directory has to be
a copy, because the shell's QML scanner rejects symlinked plugin paths.

## CLI

`headsetctl` is the plugin's backend, and you can also use it on its own:

```
headsetctl status                          # JSON snapshot
headsetctl toggle | music | call | duplex  # mode switch (with OSD)
headsetctl connect|disconnect <mac>
headsetctl default-sink <sink>             # also moves running streams
headsetctl autoswitch on|off
headsetctl usb -s 64                       # any HeadsetControl flags
```

`HEADSET_CARD=bluez_card.XX_…` pins which Bluetooth card the mode commands
use.

## Thanks

A huge thank you to **[Sapd](https://github.com/Sapd)** and everyone who
contributes to [HeadsetControl](https://github.com/Sapd/HeadsetControl). They
spent years reverse-engineering the USB protocols of dozens of gaming headsets
from SteelSeries, Logitech, Corsair, HyperX and others. Without that work, much
of this plugin would not be possible: the battery level, sidetone, ChatMix, EQ
presets and the rest of the USB headset controls all come from HeadsetControl.
If it's useful to you too, consider starring or supporting the project.

The Bluetooth mode switching builds on
[headset-mode](https://github.com/stikkx/headset-mode).
