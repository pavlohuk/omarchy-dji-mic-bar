# DJI Mic for the Omarchy bar

Omarchy shell port of [DJIMicBar](https://github.com/pavlohuk/DJIMicBar): a bar widget for the
DJI Mic Mini 2 with its USB-C receiver. It shows only while the receiver is plugged in.

- Bar icon: microphone with four dots, a battery gauge for the weakest transmitter.
- Panel: battery, live input level, Voice Tone, Low Cut, LEDs, Auto Off, Limiter, Mono/Stereo.
  Noise cancelling is display only (switched on the device).
- Keys: arrows / hjkl move, Enter or Space toggles, `I` shows firmware and serial numbers.
- IPC: `omarchy-shell huk.dji-mic toggle`.

## Setup

1. `sudo ./install-udev-rule.sh` once, so the user session may open the receiver.
2. `omarchy bar put huk.dji-mic --after omarchy.tray`

## Files

| File | Role |
|---|---|
| `dji-mic-helper.py` | USB side (usbfs, no dependencies): decodes status, sends commands, JSON lines on stdout |
| `Panel.qml` | bar button and panel |
| `MicIcon.qml` | bar mark |
| `i18n/` | English and Ukrainian strings |

Protocol credit: [ShadowBitBasher/DJI-Mic-Control](https://github.com/ShadowBitBasher/DJI-Mic-Control).
Not affiliated with DJI; product images belong to DJI.
