// The sampler instrument: one sample, up to eight voices, six playback algorithms.
//   MELODIC  pitched by the note, ADSR, plays the window once
//   ONESHOT  pitched by the note, always plays the whole window (note off is ignored)
//   LOOPED   pitched by the note, ADSR, the window loops while the key is held
//   KIT      the sample is cut at its hits into 16 slices; a note plays one slice unpitched (pad = note - 60)
//   GRAIN    a cloud of short overlapping grains picked at random inside the window
//   PAUL     the window smeared into an endless pad (spectral time stretch)
#pragma once
#include "Adsr.h"
#include "Common.h"
#include "Paul.h"
#include "Slicer.h"
#include <memory>
#include <string>
#include <vector>

struct SampleBuf {
    std::vector<float> d;   // interleaved stereo
    int frames = 0, sr = SAMPLERATE;
};

class Sampler {
public:
    enum Mode { MELODIC, ONESHOT, LOOPED, KIT, GRAIN, PAUL, kModes };
    static constexpr int kVoices = 8;

    Sampler(int engineRate);
    ~Sampler();
    // worker thread: reads a WAV, normalises it, finds the slices and the overview peaks
    bool load(const std::string& path);
    const std::string& label() const { return label_; }
    const std::vector<float>& peaks() const { return peaks_; }   // 512 bins, 0..1
    std::shared_ptr<const SampleBuf> original() const { return orig_; }

    // audio thread
    void setMode(int m);
    void setEnv(float attack, float decay, float sustain, float release);
    void setRange(float a, float b);   // 0..1 of the original sample
    // the offline stretched / pitched copy of the range [a, b] (null: play the original)
    void setProcessed(std::shared_ptr<const SampleBuf> p, float a, float b);
    void setBend(float semitones) { bend_ = semitones; }
    void setRoot(float note) { root_ = note; }   // the note at which the sample sounds as recorded (60 = C4; auto-tune sets the detected pitch)
    // the parameters of the modes that replace speed / pitch on the sample page
    void setSliceThreshold(float thr01) { sliceThr_ = thr01; reslice(); }   // KIT: how sharp a rise must be to start a slice (0 many slices .. 1 few)
    void setKitPitch(float semis) { kitSemis_ = semis; }                    // KIT: every slice is transposed by this
    void setGrain(int count, float scatter) { grainN_ = std::min(12, std::max(1, count)); grainScatter_ = std::min(1.f, std::max(0.f, scatter)); }   // GRAIN: grains sounding together, how far around the cursor they start
    void setPaul(float stretch, float width) { paulStretch_ = std::min(100.f, std::max(1.5f, stretch)); paulWidth_ = std::min(2.f, std::max(0.f, width)); }   // PAUL: slow-down factor, stereo width (1 = as is)
    std::vector<float> sliceFractions() const;   // KIT: where the slices start (0..1 of the sample) and, last, where the last one ends
    void noteOn(int note, int vel);
    void noteOff(int note);
    void allOff();
    void setTransportPlayback(bool play);
    void clearTransportPlayback();
    bool transportPlaybackActive() const;
    float transportPlaybackPosition() const;
    void seekTransportPlayback(float position);
    void render(float* out /*stereo, added*/, int n);
    int voicePositions(float* out, int maxN, float* level = nullptr) const;   // read positions 0..1 of the original sample
    bool hasVoices() const;

private:
    struct Grain { bool on = false; double pos = 0, inc = 0; int age = 0, len = 1; };
    struct Voice {
        bool on = false, gate = false; int note = 0, slice = 0; float vel = 1.f; uint32_t born = 0;
        double pos = 0, rate = 1.0, ws = 0, we = 0;   // window of the played buffer, frames
        const SampleBuf* buf = nullptr;
        Adsr env; Grain grain[12]; double spawn = 0; int paulIdx = -1;
    };
    void resolveWindow(Voice& v, const SampleBuf*& buf, double& ws, double& we) const;
    float orginalPosOf(const Voice& v) const;
    void renderVoice(Voice& v, float* out, int n);
    void reslice();
    float rnd() { rng_ = rng_ * 1664525u + 1013904223u; return (rng_ >> 8) / 16777216.f; }

    int sr_;
    std::shared_ptr<const SampleBuf> orig_, proc_;
    float procA_ = 0, procB_ = 1, rangeA_ = 0, rangeB_ = 1, bend_ = 0, atk_ = 0.01f, dec_ = 0.3f, sus_ = 0.8f, rel_ = 0.3f, root_ = 60.f;
    int mode_ = MELODIC; std::vector<int> slices_; std::string label_; std::vector<float> peaks_;
    Voice voices_[kVoices]; std::vector<std::unique_ptr<PaulStream>> paul_; bool paulBusy_[kVoices] = {};
    std::vector<Onset> onsets_; float sliceThr_ = 0.22f, kitSemis_ = 0.f, grainLen_ = 0.12f, grainScatter_ = 1.f, paulStretch_ = 8.f, paulWidth_ = 1.f; int grainN_ = 7; double sliceEnd_ = 0;
    uint32_t transportVoice_ = 0;
    bool transportPaused_ = false;
    uint32_t bornCounter_ = 0, rng_ = 7;
};
