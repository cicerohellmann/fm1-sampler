# fm1-sampler for iOS

The iPhone build of the sampler + looper. Like the Android app, everything that sounds, behaves or is drawn lives in the shared C++ engine
(`engine/`: Session, SamplerApp, SamplerUI); this folder is only the platform shell around it.

| Android | iOS | Does |
|---|---|---|
| `native-lib.cpp` (JNI) | `Core.*` | Session + SamplerApp + SamplerUI behind one mutex, the MIDI byte parser (running status, SysEx across chunks) |
| Oboe streams | `AudioIO.*` | one RemoteIO unit, 44.1 kHz float client format (iOS converts if the route runs at another rate), the built-in mic as input (never the USB device), mixable session, interruption / route change / media-reset recovery |
| `Backend.java` MIDI part | `MidiLink.*` | CoreMIDI: finds the FM-1 by name (m-vave / fm-1 / fm1 / fm), follows plug and unplug, UMP (MIDI 1.0 protocol) to bytes in, SysEx bytes to UMP SysEx7 out |
| `Backend.java` ticker | `Backend.*` | the ~60 Hz surface thread: app tick, SysEx out, link state, file requests |
| `SamplerView.java` | `SamplerView.*` | replays the UI's draw ops with Core Graphics (Menlo, the monospace `SamplerUI::fit` assumes), one-finger touch; the layout gets the safe area (860 x 400 units minimum, scaled to fit) |
| `SamplerActivity.java` | `ViewController.*`, `AppDelegate.*` | full screen landscape, status bar and home indicator hidden, edge gestures deferred (the timeline sits at the bottom edge), system file picker, screen kept on |
| `AudioImport.java` (MediaCodec) | `AudioImport.*` (AVAudioFile) | a picked file -> `sample_<name>.wav` (16-bit, its own rate, max 90 s, max 2 channels) |

Data: `Documents/` holds the saved samples (`sample_*.wav`, the "User" group of the library) and the theme; it is visible in the Files app,
so WAVs named `sample_*.wav` can be dropped in and recordings taken out. The bundled library is read in place from the app bundle (`samples/`).
Audio keeps running in the background (background mode `audio`), like the Android app keeps running behind other apps.

## Connecting the FM-1
USB: the FM-1's USB cable into the iPhone's USB-C port (USB-C to USB-C, or the FM-1's cable with a USB-C adapter). That one cable carries MIDI
(keys, buttons, encoders, its screen, LEDs) and the audio to the FM-1's jack. No Bluetooth, no pairing. Flash the firmware of this repository first
(`firmware/FM1-Sampler-Workbench.html`, see the main README). Without the FM-1 the app plays through the phone's speaker or headphones.

## Build and install
Needs Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the project is generated from `project.yml`; the generated
`FM1Sampler.xcodeproj` is checked in so Xcode alone also works).

```
cd ios
./run-device.sh            # Release build, installs and launches on the first available iPhone (USB or Wi-Fi), console attached
./run-device.sh Debug      # the engine is compiled -O2 in every configuration: a -O0 engine would not keep up in real time
```
Signing: automatic, team `E9C9AGS9K6`, bundle id `ca.dallasgroot.fm1sampler` (change both in `project.yml` for another account).
`DEVICE=<CoreDevice id>` picks a phone (`xcrun devicectl list devices`). The phone must be unlocked with its screen on for a remote launch.

## Testing on the phone without the FM-1
Off unless switched on, through the launch environment or `Documents/diag.env` (KEY=VALUE lines, put there with
`xcrun devicectl device copy to --domain-type appDataContainer --domain-identifier ca.dallasgroot.fm1sampler`):

| Switch | Does |
|---|---|
| `FM1_DIAG=1` | engine / audio / MIDI state every 2 s, written to `Documents/diag/log.txt` too |
| `FM1_SNAP=<ms>` | the phone screen as `Documents/diag/snap_NN.png` every `<ms>` |
| `FM1_SCRIPT=...` | timed actions, `;` separated: `<ms> tap <x> <y>`, `<ms> drag <x1> <y1> <x2> <y2> <dur>` (UI units, logged as `layout:`), `<ms> note <n> <hold>`, `<ms> snap <name>` |
| `FM1_IMPORT=a.m4a,b.aif` | imports `Documents/import/<file>` as if picked |
| `FM1_NETMIDI=1` + `FM1_MIDI_MATCH=session` | opens the network MIDI session and takes it as the FM-1 |

`tools/fm1emu.mm` is the FM-1 on the Mac: it joins that session over AppleMIDI / RTP-MIDI, plays the FM-1 side of `PROTOCOL.md` (keys, buttons,
encoders, SCALE every 2 s, PONG for PING, REDRAW on connect, RTP losses reported as dropped frames) and decodes the screen commands with
`engine/tools/fm1_screen.h` into PNGs:

```
clang++ -std=c++20 -fobjc-arc -I../engine/tools tools/fm1emu.mm -framework Foundation -framework CoreGraphics -framework ImageIO -o fm1emu
./fm1emu --address <iPhone ip> --out shots --script "wait 1500; snap home; btn 4; enc 2 5; snap env; key 60 400; expect pings 2"
```

## Tested on an iPhone 17 Pro (iOS 27.0.1), without the FM-1
- Audio: RemoteIO at 48 kHz hardware / 44.1 kHz engine, 5 ms buffer, steady 200 callbacks/s; speaker and AirPods (A2DP) routes; the mic as input.
- CPU of the audio thread: idle ~1 %, Paulstretch with 4 voices ~6 %, granular with 32 grains ~5 %.
- FM-1 protocol through CoreMIDI (network session + emulator): every page button, all encoders, keys, all six algorithms, preset audition,
  first take / loop / LENGTH x2 / transport, LEDs, PING / PONG, REDRAW, BATCH; 70 PONGs and 6500 screen commands in one run, no drops.
- Phone UI: theme, library, project menu, editor, all ten page schematics, knob drag, voices, looper from the phone, timeline scrub, stop,
  microphone sampling (the phone's own speaker as the source).
- Import: AAC, ALAC, 24-bit AIFF, float WAV, 22 kHz CAF; a broken file is refused; a 120 s file is cut at 90 s.

Not tested (no hardware): the FM-1 over USB itself (USB MIDI and USB audio routing). CoreMIDI treats USB and network endpoints the same way,
and iOS routes the output to a USB audio device on its own, but the first session with the FM-1 should check: the FM-1 is found
("FM-1 source" in the log), its screen and LEDs, the audio on its jack, the built-in mic still being the input while the FM-1 is plugged in.
