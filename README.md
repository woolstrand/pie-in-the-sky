# BT Latency Proxy

A macOS menu bar app that fixes video freezing and lagging with Bluetooth headphones whose
reported latency is wrong.

## The problem

You start or seek a video while listening on Bluetooth headphones. The sound starts at once,
but the picture freezes for a second or two and then jumps to catch up. This happens in Safari,
Chrome, QuickTime, IINA and anything else built on AVFoundation or that reads the device
latency. VLC is not affected. Wired headphones are fine.

### Cause

Each A2DP headphone tells the Mac its playback delay through an AVDTP *delay report*, in
units of 0.1 ms. macOS takes that value as is:

```
bluetoothd: A2DP Latency = 1523 ms (1500 ms DelayReport + 23 ms RTP blocking)
```

It then publishes the value as the output device's `kAudioDevicePropertyLatency`. Players
delay the picture by that amount so it lines up with the sound. When the headphone reports
nonsense, every player dutifully holds the picture back by 1.5 seconds.

The headphone this was found on (Fresh 'n Rebel Clam 2) reports `15000` (1.5 s) whenever the
Mac initiates the connection. It reports `1500` (150 ms) when the headphone connects by itself,
for example right after it is switched on. The codec is the same in both cases. As a stopgap,
turn the headphone off and on and let it reconnect on its own.

macOS has no setting to override the reported latency. Aggregate and Multi-Output devices don't
help either: they adopt the largest sub-device latency.

### Fix

The app installs a small virtual output device, **BT Latency Proxy**, which reports a sane,
adjustable latency (250 ms by default). When your Bluetooth output reports an absurd value, the
app does three things:

1. Makes BT Latency Proxy the default output.
2. Forwards its audio straight to the headphones through its own IO, so the real audio path
   stays as short as the headphones allow.
3. Mirrors the volume both ways. The volume keys, the menu bar slider and the headphone buttons
   all keep working and stay in sync.

Players now see 250 ms instead of 1500 ms and keep the picture in sync. When the headphones
disconnect, or you pick another output, the app steps aside.

## Requirements

- macOS 15 or later (Apple silicon or Intel)
- Xcode Command Line Tools, to build: `xcode-select --install`

## Install

```bash
git clone https://github.com/woolstrand/bt-latency-proxy.git
cd bt-latency-proxy
make install
```

This builds the app, copies it to `/Applications` and starts it. On first launch the app offers
to install its audio driver. Installing asks for an administrator password and interrupts audio
for about a second while `coreaudiod` restarts. No reboot is needed.

The build is signed ad hoc on your machine, so Gatekeeper doesn't complain. Prebuilt downloads
would need a paid Developer ID for notarization, so none are provided yet.

## Use

The app lives in the menu bar (headphones icon; filled while it is active).

| Menu item | What it does |
|---|---|
| **Automatic** | Turns automatic routing on or off. |
| **Engage when latency is above** | The app steps in only if the Bluetooth output reports more than this (300 / 500 / 800 ms) or always. With well-behaved headphones the proxy isn't needed. |
| **Video delay** | The latency the proxy reports, which is how long players hold back the picture. If the picture is ahead of the sound, increase it. If the sound is ahead, decrease it. Applies immediately. |
| **Open at Login** | Starts the app when you log in. |
| **Install / Update / Reinstall Driver…** | Manages the audio driver. |
| **Uninstall…** | Removes the driver and the login item, then quits. |

The status lines show the latency the headphones report, what players now see, and forwarding
health: buffer, clock drift in ppm, and resyncs. Resyncs should stay at 0.

To see what every output reports:

```bash
swift tools/audio-latency.swift
```

## Uninstall

Use **Uninstall…** in the menu, then move the app to the Trash. Or run `./uninstall.sh`.

## How it works

- `driver/` is a CoreAudio AudioServerPlugIn, a loopback device derived from
  [BlackHole](https://github.com/ExistentialAudio/BlackHole) 0.7.1. Changes from BlackHole:
  - The output latency comes from a custom property `'btlt'` (milliseconds, persisted by
    coreaudiod), so the app can change it at runtime.
  - The volume control no longer scales the samples, because the app applies it to the
    headphones instead.
- `app/` is the menu bar app.
  - `Forwarder.swift` reads the loopback with one IOProc and writes to the Bluetooth device with
    another. A ring buffer sits between them. It holds about 23 ms and is kept steady by
    varying the read speed by at most ±0.2 % with linear interpolation, because the two devices
    run on different clocks.
  - It deliberately doesn't use an aggregate device: an aggregate would adopt the bogus latency
    and add that much real delay.
  - `Controller.swift` decides when to engage and handles device changes, sample-rate changes
    (for example, the headset switching to the hands-free profile) and volume mirroring.

## Known limitations

- While engaged, the Bluetooth audio stream stays open even when nothing plays. Some headphones
  may then not enter their power-saving state.
- Stereo only.
- Audio produced before the app engages (the first moments after the headphones connect) goes
  to the headphones directly.
- Tested on macOS 26 with one pair of headphones. Reports from other models are welcome.
  Include the output of `tools/audio-latency.swift`.

## License

GPL-3.0, see [LICENSE](LICENSE). The driver is derived from BlackHole by Existential Audio Inc.
This project is not affiliated with Existential Audio.
