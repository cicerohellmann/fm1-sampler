# fm1-sampler

> **iOS port.** This fork of [ferluht/fm1-sampler](https://github.com/ferluht/fm1-sampler) adds a native iPhone app in [`ios/`](ios/README.md): the same C++ engine, UI and FM-1 protocol, with a CoreAudio / CoreMIDI / CoreGraphics shell in place of the Android one. Tested on an iPhone 17 Pro (see the iOS README for what was and was not tested).

A **sampler + audio looper** (8 tracks) for Android and iOS (see [ios/README.md](ios/README.md)) with the M-VAVE FM-1 as its hardware front end. The phone does all the sound; the FM-1 is the
control surface (keys, buttons, 7 encoders), the second screen (240x240, drawn with SysEx commands) and the audio output (USB audio).
All DSP is original code in `engine/dsp` (no third-party audio engine); the only library is KissFFT (BSD) for the Paulstretch mode.

## Screenshots
FM-1 second screen (240x240, from the host simulator `app_sim`: sample, FX, envelope, LFO, arp, tape, mixer, key, mic waiting, rec armed, loop playing, loop length):

![FM-1 screens](shots/readme_fm1_v37.png)

Phone app, main screen = the tape deck (light theme by default, the dark one is one tap away; ink / dim / orange): the tape loop, PLAY / STOP / REC / CLEAR under it, the sample of the selected track with its mode and sounding voices, the four knobs of the current page, one timeline of the selected track:

![Cassette deck](shots/readme_deck_v37.png)

The same screen while the first loop is recorded (its waveform grows on the timeline) and while a microphone take waits for sound (level, trigger lines, STOP / CANCEL):

![First take](shots/readme_firstrec_v37.png) ![Microphone](shots/readme_mic_v37.png)

## Downloads
APK and the flash page of the matching firmware are attached to the [releases](../../releases) of this repository. Flash the firmware first (SEL = loop length page needs it), then install the APK.

## FM-1 controls
| Control | Does |
|---|---|
| SELECT (encoder 0) | track 1..8 |
| PRESETS (encoder 6) | browses the sample library; after 250 ms of rest the entry is loaded on the selected track and played (audition) |
| ALGORITHM (encoder 1) | MELODIC, ONE-SHOT, LOOPED, KIT/SLICE, GRANULAR, PAULSTRETCH (the Sampler's MODE; KIT slices on transients, equal parts if there are none) |
| K1..K4 (encoders 2..5) | the four parameters of the current page (below) |
| HOME | sample: START, END, then K3 / K4 depend on the mode. MELODIC / ONE-SHOT / LOOPED: SPEED (time stretch 0.25..4x), PITCH (+-24 st), both offline stretches applied 350 ms after the knob rests. KIT: THRESHOLD (the level a hit must reach to start a slice, 2..60 % of the loudest part, log; START / END limit where the sample is cut; the phone marks the cuts with the number of the key that plays each, C = 1) and PITCH (every slice transposed in real time). GRAIN: GRAINS (1..12 sounding together) and SCATTER (a cursor sweeps the window in about 4 s; grains start within scatter x window around it, 100 % = anywhere; grains are 120 ms). PAULSTRETCH: STRETCH (slow-down 2..64x, taken when a note starts) and WIDTH (stereo width 0..200 %) |
| FX | two global send effects (one reverb, one delay for the whole loop, every track sends into them): K1 REVERB SEND and K3 DELAY SEND of the selected track, K2 REVERB SIZE and K4 DELAY TIME (global; return levels and delay feedback are fixed) |
| ENV | ATTACK, DECAY, SUSTAIN, RELEASE of the selected track |
| LFO | RATE (0.1..20 Hz), DEPTH, TARGET (PITCH, FILTER, VOLUME, PAN), SHAPE (SINE, TRI, SQUARE, S&H) |
| ARP | RATE (OFF, 1..64 with triplets), PATTERN, OCTAVES, LENGTH (own arpeggiator on the tempo grid, free running) |
| SEQ ("TAPE") | LOOP SPEED (0.25..2x tape-style varispeed of the loop, GLOBAL for all tracks), EXCITER (cassette saturation), LO-FI (bit crush + hiss + dark tone), WOBBLE |
| EDIT ("MIXER") | per track: VOLUME, SC SOURCE (OFF or the track that ducks this one), SC THRESHOLD (0..-40 dB), SC RATIO (1..20 : 1). Sidechain compressor: the level of the source track (before its fader) over the threshold pulls this track down by over x (1 - 1/ratio) dB, fast attack, slow release; pan stays centred |
| GLO | key and scale: SCALE, ROOT, OCTAVE, MODE (KEY/CHORD). Drives the firmware's key mapping (SysEx 06) |
| SAVE | page LOOP only (saving and clearing loops is on the phone: the PROJECT menu code is kept but muted, CLEAR is a key of the deck). Knobs: MIC SAMPLE, LOOP SOURCE, (K3 empty), MIC THRESHOLD (-46..-6 dB, level that starts a mic take; used by mic sampling and mic loop source) |
| PLAY | play / stop (a toggle; the phone has separate PLAY and STOP keys). While recording the first press only ends the recording (the loop plays on), the next one stops the tape. Start and stop are tape-like: the loops run up from standstill (0.45 s) and slow down to it (0.7 s) |
| REC | clean looper: arms the first take (it starts with the first key or sound and sets the loop length and tempo; REC again ends it). Loop exists: toggles overdub on the selected track |
| SEL (the button after FX; index 3, the protocol and the firmware call it SCL) | page LENGTH: K1 LENGTH (turn up = loop x2 with its content repeated, down = /2), K2 DUPLICATE, K3 HALVE, K4 bars/bpm (read-only). Needs the firmware built here (`firmware/FM1-Sampler-Workbench.html`): it forwards SCL as button 3 and has no scale screen; the stock/fm1-daw firmware keeps SCL local |
| OCT -/+ | handled by the firmware (octave) |
| keys | KIT algorithm: all 27 keys are pads (note 60 + key, 16 slices repeat over the keys), every key lit, tonality and octave ignored. Otherwise the firmware is kept on a plain chromatic keyboard (scale OFF, SysEx 06 always sends 7; notes 53+key) so keys outside the tonality still play; the app adds the octave, builds triads itself in CHORD mode and lights ONLY keys that belong to the scale (root of each octave blinks; scale OFF: only roots); a sounding key goes dark. |

## Levels and tuning
- Every sample is loudness-normalised on load (`Sampler::load`): the RMS of the part that sounds (20 ms blocks within 30 dB of the loudest) goes to 0.25 (gain capped at +10 dB of peak), a soft limiter (knee 0.6, ceiling 0.98) keeps the peaks, so sparse material such as drums is as loud as sustained sounds.
- Auto-tune (tuning fork pictogram in the sample view, MELODIC and ONE-SHOT only): `dsp/Pitch.h` (YIN on the loudest window of the first 1.5 s) finds the pitch, the track's root note becomes that pitch (`Sampler::setRoot`), so the keys sound the right notes; tap again to reset. A new sample resets it. The phone CLEAR key clears the loop of the selected track.

## Phone screen (the deck)
One visual system (light by default, dark one tap away): one grid, one line weight (2.7 units), ink + a dim tone + one orange for what is live, solid shapes, no frames, no cards. Laid out for 400 units of height, margin 24.
- **Header** (top left): the track number (orange, tap = next track), the sample name (tap = library) and under it the position in the loop (a toast or the microphone state replaces it for a moment).
- **Tape loop**: one closed ribbon over a big and a small wheel (built from common tangents + arcs), it runs once round per loop, the orange dot is the splice = loop start. Without a loop it stands still.
- **Transport** under it, icons only: PLAY, STOP, REC (OVERDUB when a loop exists), CLEAR (clears the loop of the selected track); the active one is orange with an underline. While recording PLAY / STOP only ends the recording (the loop plays on), the next press stops the tape. Start and stop are tape-like (run-up 0.45 s, slow-down 0.7 s, level follows the speed).
- **Tools column** (middle, 64 units pitch, the lowest icon on the transport row): theme (light / dark, remembered in `<data dir>/theme`), microphone, file from disk, project menu (`projectSheet`: save / clear loop, clear all (tap twice), loop x2 and /2, loop source, open the editor).
- **Sample view** (top right), page SAMPLE: the waveform with the playback window dark, the playback mode on top (tap = next mode), one orange line per sounding voice (height follows the voice envelope), the voice count, the tuning fork (auto-tune, MELODIC / ONE-SHOT only). While a microphone take waits for sound the view shows the input level and two trigger lines (drag up / down to set the level) and one STOP / CANCEL button; while it records, the growing take (normalised).
- **Page schematics** (`pageView`, the same place, every other page): FX = a wire cube (the room: size, wet rays) and an echo (a circle and its shrinking repeats: time, feedback); ENV = the ADSR curve; LFO = the shape over a few cycles with the live value as an orange bar; ARP = the notes in pattern order; TAPE = a wave that wobbles, saturates and turns into stairs; MIXER = the last four seconds of the active channel scrolling: its level as a mirrored wave (dim = what it would be, ink = what is left after the sidechain), the source level as an envelope with the dashed threshold, orange where the source is over it, and the reduction in dB; KEY = two octaves with the scale and the root; LOOP = input level against the trigger line; LENGTH = the loop as bars with the playhead. They are computed from the same values as the knobs.
- **Page**: the name of the current page (orange) with ten notches (tap one = that page, like the FM-1 buttons); under them the four knobs of the page (ring + orange arc + pointer, drag up / down), the same parameters as K1..K4 on the FM-1.
- **Timeline** (bottom): bar numbers, the waveform of the selected track's loop (played = ink, to come = dim), the orange playhead. Drag = tape scrub (`Session::scrubBegin / scrubMove / scrubEnd`): the tape follows the finger with a smoothed speed (up to 6x, forward and backward, the pitch follows like a hand on a reel, no clicks); when the finger lifts the tape returns to the transport speed or stops where it is. While the first take is recorded its waveform grows here.
- The old editor (EDIT view) is opened from the project menu; its DECK button comes back. It uses the same theme.

**FM-1 screen** (240x240) uses the same system (`SamplerApp::draw`, colours from `ui/Theme.h`, so it follows the phone's theme): track number and sample name, the transport state as the same pictogram, the page name with eight track notches, a 46 px picture of the page (waveform, ADSR, LFO, mixer, key, loop length, microphone level), the loop line, four values (3x pixel font, 2x when longer than six characters) with orange bars, the button hint.

## FM-1 LEDs
The active page button is lit. The firmware may light or clear a button LED by itself when it is pressed, so the LED frame (SysEx 01) is resent after every button event and every 400 ms.

## Sample sources
- **Bundled library** (`samples/`, packed into the APK assets, copied to `files/samples` once): Bass, Drums (loaded as KIT), Keys, Pads.
- **Microphone**: the microphone pictogram of the phone sample view or LOOP page K1. Waits for sound above the trigger level, trims and normalises, saves `sample_<ms>.wav` in the data dir, loads it on the track it was started on.
- **Disk**: the folder pictogram of the sample view -> system picker -> `AudioImport.java` converts to a 16-bit WAV (`sample_<name>.wav` in `files/`): WAV 8/16/24/32/float directly, anything else through MediaCodec (mp3, aac, ogg, flac). Max 90 s.
- **Saved loops** and the two above all live in the "User" group of the library (`sample_*.wav` in the data dir).
Browsing replaces the sample of the selected track; a new sampler keeps the track's settings (`applyAll` after `sampleVersion` bumps).
Default envelope release 2.0 s. At start every track with a sample gets its settings applied (several samples can land between two ticks).
At start: Tape Key on track 1, Acoustic bass on 2, Shiny on 3, TrapKit (KIT) on 4.

## Looper details
- Loop source (LOOP page K2; on the phone the PROJECT menu, muted for now): SOUND = what the track plays (keys, arp, sample, filter, before the cassette) or MIC. Default SOUND.
- One clip per track; all tracks share the loop length of the first take. All loops are read (and recorded) through ONE tape pointer (`Session::tapePos`), so LOOP SPEED moves them together. At 1.0x the pointer is locked to the transport.
- Recording into the loop works at any speed like a tape head: below 1x the input is spread over the two neighbouring cells weighted by the speed, above 1x the skipped cells are filled by interpolating the input.
- A free take records audio only (no notes), so nothing in the loop runs at a speed of its own.
- Exciter / lo-fi / wobble are global: a per-track cassette (saturation, tone, wow and flutter, hiss, mix) followed by a bit crusher.
- Reverb and delay run 100 % wet as send returns; D/W is the return gain (`Session::setRetLevel`).
- The whole-loop overview in the phone UI (`Session::loopPeaks`) is refreshed by the audio thread, 8 of 400 bins per block.

## Engine
- `engine/dsp/Sampler.*`: the instrument. Up to 8 voices; MELODIC, ONE-SHOT, LOOPED (crossfaded loop), KIT (16 slices cut at the hits by `Slicer.h`, pad = note - 60), GRANULAR (Hann grains at random positions in the window), PAUL (`Paul.*`: windowed spectra with random phases, overlap-add, at most 4 voices). `Adsr.h`, `Filter.h` (state variable low-pass, used by the LFO filter target).
- `engine/dsp/Stretch.*`: offline time stretch (WSOLA) and pitch shift (stretch + resample) of the sample window; built on the worker thread 350 ms after the SPEED / PITCH / START / END knob rests, then swapped in.
- `engine/dsp/Reverb.h` (8 combs + 4 allpasses per side), `TapeDelay.h`, `TapeInsert.h`, `Arp.h` (UP, DOWN, UPDN, CONV, RAND over 1..4 octaves, sample accurate gate), `Wav.*`.
- `engine/session/Session.*`: tracks, mixer, LFO (once per block, ~170 Hz: pitch, filter, volume or pan), looper, mic recorder, library listing, command queue to the audio thread, worker thread. `status()` is lock-free.
- `engine/app/SamplerApp.*`: all behaviour: knob pages (`knobs(Page)` is the single source for FM-1 and phone), per-track state, library, looper, FM-1 screen drawing and LEDs, SysEx pacing and loss recovery.
- `engine/ui/SamplerUI.*`: the phone UI as draw ops (`UiOp.h`; `Theme.h` is the dark / light theme of the EDIT view, the deck has its own black / white / orange constants). Default view = `deck` (see "Phone screen"); EDIT switches to the older editor (left track list, centre sample / waveform with draggable START / END, voice markers, whole-loop lane, right page tabs + 4 sliders, library sheet; the sliders pictogram in the bottom right corner of the deck opens it, the DECK button returns).
- `android/`: `Backend` (FM-1 USB MIDI + USB audio routing, Oboe, 30 Hz tick), `SamplerActivity` (full screen with sticky immersive bars, file picker, mic permission, `files/crash.log` for Java crashes), `AudioImport`, `SamplerView` (replays ops), `native-lib.cpp`. Package `com.ferluht.fm1sampler`, lib `fm1sampler`.
- `firmware/`: the FM-1 firmware (M-VAVE's open firmware with the control-surface protocol of `PROTOCOL.md`). `firmware/FM1-Sampler-Workbench.html` is the flash page; `tools/build_fw.py firmware ~/fm1/wine/drive_c/JL/pi32` rebuilds it (JieLi toolchain under wine, ~30 s). Changes in `app/ctrl.c`: SEL (BTN_SCL) forwarded to the app (no on-device scale screen), splash "SAMPLER".

## Build and test
- Host: `make -C engine -j4`, then `make $PWD/engine/build/<t>` with t = `test_app` (checks: every algorithm, LFO targets, stretch and pitch, tape, arp, loop, speed, overdub, loop length, voices, KIT keys, save/clear, mic, disk import, audition, DSP units), `app_sim` (virtual FM-1, writes `app_NN_*.ppm` screenshots of its screen), `phone_render` + `python3 engine/tools/render_ui.py ui_ops.json outdir 1.5` (phone screenshots), `probe` (what the default project loads). Paths in the tools assume `~/fm1-sampler/samples`. The tools sleep a little per audio block so the worker thread (sample loading) keeps up with the simulated time.
- Android: `cd android && ANDROID_HOME=~/android-sdk ~/gradle/gradle-8.9/bin/gradle assembleDebug -q` (~4 min first, never edit engine sources while it compiles: clang then reports "source file is not valid UTF-8"). Output `app/build/outputs/apk/debug/app-debug.apk`.

## Status
Host-tested only (test_app all green, screenshots of both screens checked). **Not run on a phone or an FM-1** since the deck redesign. Things to check on the device: the USB plug crash fix (cause was not seen in a log: the audio stream restart was moved off Oboe's thread, the FM-1 MIDI port is opened once, MIDI parsing handles running status / real-time bytes; a Java crash lands in `files/crash.log`), the page LEDs of the FM-1 (resent every 400 ms), tape scrub feel (follow time 70 ms, speed limit 6x), tape start / stop times, the loudness of drums after the RMS normalisation, auto-tune on real samples. Open questions: MediaCodec import on a real phone, offline stretch time on the phone CPU, Paulstretch / granular CPU on the phone, arp is free running (not locked to the loop), loop clips are not saved with a project (no project save/load).

## Branches
- `main` = v0.37 (the cassette-deck work was fast-forwarded into it).
- `cassette-deck` = v0.11 .. v0.37 (merged into `main`): the phone screen is the tape deck; no patterns and no punch-in effects. From v0.30 the phone and the FM-1 screen share one visual system (light default theme with a dark variant, ring knobs). v0.32..v0.37 add page schematics in the place of the sample (FX, ENV, LFO, ARP, TAPE, MIXER, KEY, LOOP, LENGTH), per-mode K3/K4 on the sample page (KIT threshold + slice markers, GRAIN count + size, PAUL stretch + width), FX as global send effects with per-track sends, and MIXER = volume + sidechain compressor with a scrolling wave picture. Last APK: `fm1sampler-v0.37.apk`; host-tested only.
- `patterns-punchin`: the parked patterns (LEN + keys 1..8) and punch-in effects (MIXER keys), host-tested.
