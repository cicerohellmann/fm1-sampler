# FM1 Sampler for iPhone

This target runs the shared C++ sampler engine in a SwiftUI app. It supports
portrait and landscape on iPhone and targets iOS 16 or later.

## Build and run

1. Check out the branch containing this change. Keep the repository's top-level
   `samples/` directory beside `engine/` and `ios/`.
2. Open `ios/FM1Sampler.xcodeproj` in Xcode. Select the FM1Sampler scheme and an
   iPhone simulator. Use Product > Run.
3. To run on an iPhone, select your own team under Signing & Capabilities and
   use a bundle identifier registered to that team. Select the connected iPhone
   and run the same scheme.
4. After editing `ios/project.yml`, run `xcodegen generate` from `ios/` to
   regenerate the project. Xcode may need you to reselect your signing team.

An unsigned Release build for Simulator can also be built from the repository root:

```sh
xcodebuild -project ios/FM1Sampler.xcodeproj -scheme FM1Sampler \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Use and test on iPhone

- Tap the folder icon or LOAD FILE. Select a WAV, M4A, or MP3 in Files.
  Imported audio goes into the User sample library as PCM WAV, up to 90 seconds.
  Cancel and reopen the picker, then import another file with the same name.
- Tap Play, pause mid-sample, then resume. Drag across the sample waveform to
  seek. Tap Stop and check that playback returns to the sample's START setting.
- Record a loop, enter the editor through Project, and drag the lower loop strip.
  Check seeking both during playback and while paused. Use Project to save a
  loop as a sample in the User library.
- Allow microphone access. Tap MIC SAMPLE, speak to trigger recording, then stop
  and save. Verify the saved sample plays and appears in the library after restart.
- Connect an FM-1 running the sampler firmware over USB. Check hardware PLAY
  against on-screen pause, MIDI notes, the FM-1 display and audio output. Unplug
  and reconnect, then repeat. Check recording with the iPhone microphone while
  the FM-1 is the USB audio output.

## Modify the app

- `ios/FM1Sampler/ContentView.swift` presents Files and import errors.
- `ios/FM1Sampler/SamplerModel.swift` schedules drawing and engine updates.
- `ios/FM1Sampler/SamplerSurface.swift` draws the shared UI and forwards gestures.
- `ios/FM1Sampler/EngineBridge.mm` connects the UI, C++ engine and Core MIDI.
- `ios/FM1Sampler/AudioIO.mm` owns RemoteIO and the audio session.
- `ios/FM1Sampler/AudioImport.mm` converts audio to the engine's WAV format.
- `engine/ui/SamplerUI.cpp` defines layouts, controls and touch regions.
- `engine/app/SamplerApp.cpp`, `engine/session/Session.cpp` and
  `engine/dsp/Sampler.cpp` implement transport, loop state and sample playback.
