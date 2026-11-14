// Session: the audio engine of the sampler app. Eight sampler tracks (arpeggiator, filter, cassette, volume/pan, reverb and delay sends),
// one audio looper whose clips share a tape clock, a microphone sample recorder.
//
// Threads: the audio thread calls process(). Everything else may be called from any other thread; changes reach the audio thread
// through a command queue drained at the start of each block. status() and the peak views are lock-free.
#pragma once
#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

class Session {
public:
    static constexpr int kTracks = 8;
    static constexpr int kVoiceMax = 32;
    static constexpr int kLoopBins = 400;

    struct Status {
        bool playing;
        bool samplePlaying[kTracks];
        float samplePlaybackPosition[kTracks];
        double pos;              // samples inside the loop
        double loopSamples;      // 0 = no loop yet
        float bpm;
        int loopBars;
        float master_peak;
        float track_peak[kTracks];
        bool track_has_clip[kTracks], track_clip_rec[kTracks];
        uint32_t cpu_permille;   // audio block time / block duration, smoothed
        bool freeRecording; float freeSeconds;
        bool freeArmed;          // free take armed: waiting for the first sound
        int sampleState;         // 0 idle, 1 recording, 2 working, 3 waiting for sound
        bool samplePending;      // a recorded sample waits to be loaded
        int sampleTrack; float sampleSeconds, inputPeak;
        int sampleVersion;       // bumps when a sample was loaded into a track (sampleTrack)
        int sampleFails;         // bumps when a sample could not be loaded
        float clipPos[kTracks];  // 0..1 read position of the loops (follows the loop speed)
        float lfoValue[kTracks]; // -1..1, for the UI
        float scGain[kTracks], scLevel[kTracks];   // sidechain: the gain a track is pulled down to (1 = untouched) and the level it is measured by (its own level before the fader)
        int voiceN[kTracks]; float voicePos[kTracks][kVoiceMax], voiceLvl[kTracks][kVoiceMax];   // + their envelope levels (a voice shrinks as it dies away)   // sounding voices (every grain in granular mode): read positions 0..1 of the whole sample
    };
    struct Lfo { float rate = 1.f, depth = 0.f, base = 0.5f; int target = 0 /*0 pitch 1 filter 2 volume 3 pan*/, shape = 0 /*0 sine 1 tri 2 square 3 s&h*/; };

    explicit Session(int sampleRate = 48000);
    ~Session();

    // ---- audio thread ----
    void process(float* out /*interleaved stereo*/, const float* in /*interleaved stereo, may be null*/, int frames);

    // ---- transport and notes ----
    void play(bool on);
    void stopAndRewind();
    void noteOn(int track, int note, int vel);
    void noteOff(int track, int note);
    void stopSamplePlayback(int track);
    void setSamplePlayback(int track, bool play);
    void clearSamplePlayback(int track);
    void seekSamplePlayback(int track, float position);

    // ---- sampler (per track) ----
    void loadSamplePath(const std::string& path, bool kit, int track);          // worker thread builds it, then it replaces the track's sampler
    void setMode(int track, int mode);                                         // 0 melodic, 1 one-shot, 2 looped, 3 kit, 4 granular, 5 paulstretch
    void setEnv(int track, float attack, float decay, float sustain, float release);   // seconds, level
    void setRoot(int track, float note);                                       // note at which the sample sounds as recorded (default 60)
    float detectRoot(int track) const;                                         // pitch of the track's sample as a (fractional) MIDI note, -1 if it has none
    void setSampleRange(int track, float start, float end);                    // 0..1 of the sample
    void setSidechain(int track, int sourceTrack, float thresholdDb, float ratio);   // the track is ducked by the level of another one (source < 0: off)
    void setSliceThreshold(int track, float thr01);                           // KIT: the threshold the slices are cut at
    void setKitPitch(int track, float semitones);                              // KIT: transposition of every slice
    void setGrain(int track, int count, float scatter);                        // GRAIN: grains sounding together and how far around the cursor they start (0..1)
    void setPaul(int track, float stretch, float width);                       // PAUL: slow-down factor and stereo width
    std::vector<float> sliceFractions(int track) const;                        // KIT: slice starts (0..1 of the sample) and the end of the last one
    void setStretch(int track, float speed, float semitones, bool commit);     // commit: the knob rested, (re)build the stretched copy offline
    void setLfo(int track, const Lfo& l);
    void setArp(int track, bool on, int rate /*0..11*/, int pattern /*0..4*/, int octaves /*1..4*/, float gate /*0.05..0.95*/);
    void setTape(int track, float sat, float tone, float wobble, float hiss, float mix, float bits);

    // ---- mixer and effects ----
    void setVolume(int track, float v);   // 0..1.5
    void setPan(int track, float p);      // -1..1
    void setSend(int track, int which /*0 reverb 1 delay*/, float level);
    void setMasterVolume(float v);
    void setReverb(float size);           // 0..1
    void setDelay(float seconds, float feedback);
    void setRetLevel(int which, float v); // reverb / delay return gain (the effects run 100 % wet)

    // ---- looper ----
    void freeRecord(int track, bool on);  // on: arm and wait for the first sound or note; the take defines the loop; off: end the take (or cancel while waiting)
    void clipRecord(int track, bool on);  // overdub on a track while the loop plays
    void clipClear(int track);
    void clipClearAll();                  // every loop: the looper is clean again
    void loopDouble();                    // loop twice as long, the content repeated (up to 3 min)
    void loopHalve();                     // half as long, the second half dropped
    void scrubBegin(float fraction);      // a finger on the timeline: the tape follows it with a smoothed speed (forward / backward, pitch follows)
    void scrubMove(float fraction);
    void scrubEnd();                      // the finger lifts: the tape returns to the transport speed, or comes to a stop
    void seek(float fraction);            // move the playhead to a place of the loop (0..1): all loops share it
    void setLoopSpeed(float speed);       // 0.25..2, tape speed of all loops together; 1 = locked to the transport
    void setLoopSource(int src);          // what the loop records: 0 microphone, 1 the track's sound
    bool saveClip(int track);             // the loop of `track` as sample_*.wav in the data dir
    int loopPeaks(int track /* -1 = all tracks mixed */, float* out, int maxBins) const;

    // ---- microphone sampling ----
    void setMicThreshold(float linear);   // level that starts a take (0.005..0.5)
    void recorderWait(bool waitForSound);
    void recorderStart();
    void recorderStop();                  // trims, normalises and writes sample_*.wav; the result becomes the pending sample
    void recorderDismiss();               // the pending sample was taken over
    std::string lastSamplePath() const;
    int freePeaks(float* out, int maxBins) const;   // the first loop while it is recorded: one peak per 10 ms
    int livePeaks(float* out, int maxBins) const;   // one peak per 10 ms of the take in progress

    // ---- library on disk ----
    void setDataDir(const std::string& dir);
    void setSampleDir(const std::string& dir);
    std::string dataDir() const;
    std::string sampleDir() const;
    std::vector<std::string> sampleFolders() const;
    std::vector<std::string> sampleFiles(const std::string& folder) const;
    std::vector<std::string> sampleLibrary() const;   // saved recordings, newest first

    // ---- views ----
    std::vector<float> samplePeaksOf(int track, int bins) const;   // waveform of the track's sample (empty if none)
    std::string trackLabel(int track) const;                       // file name of the track's sample without extension
    int sampleRate() const;
    Status status() const;

    struct Impl;
private:
    std::unique_ptr<Impl> d;
};
