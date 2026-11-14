#include "Session.h"
#include "Pitch.h"
#include "Arp.h"
#include "Common.h"
#include "Filter.h"
#include "Reverb.h"
#include "Sampler.h"
#include "Stretch.h"
#include "TapeDelay.h"
#include "TapeInsert.h"
#include "Wav.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <filesystem>
#include <functional>
#include <mutex>
#include <thread>

namespace {
constexpr int kBlock = 256;
}

struct Session::Impl {
    struct Note { int note, vel; };
    struct Track {
        std::unique_ptr<Sampler> sampler;
        mutable std::mutex infoMtx; std::string label; std::vector<float> peaks; std::shared_ptr<const SampleBuf> orig;   // for the UI threads
        // sound shaping
        Arp arp; bool arpOn = false;
        Lowpass filt; bool filtOn = false;
        Session::Lfo lfo; float lfoPhase = 0, lfoSH = 0, lfoVal = 0;
        TapeInsert tape;
        float vol = 0.8f, pan = 0.f, send[2] = {0.f, 0.f};
        // sidechain compressor: this track is ducked by the level of track scSrc (-1 off); scEnv is this track's own level, read by the others
        int scSrc = -1; float scThrDb = -20.f, scRatio = 1.f, scEnv = 0.f, scGain = 1.f;
        std::vector<Note> pending;   // notes of this block (without the arpeggiator)
        // offline stretch / pitch
        float speed = 1.f, semis = 0.f, rangeA = 0.f, rangeB = 1.f; uint32_t gen = 0;
        float sliceThr = 0.22f, kitSemis = 0.f, grainScatter = 1.f, paulStretch = 8.f, paulWidth = 1.f; int grainN = 7; std::vector<float> slices;   // mode parameters; slices for the UI (under infoMtx)
        // the audio loop of this track
        std::vector<float> clip;     // interleaved stereo, loopSamples frames
        bool clipHas = false, clipRec = false;
        bool recPrevOk = false; double recPrevCp = 0; float recPrevL = 0, recPrevR = 0;   // tape-speed recording: previous write position and input
        std::atomic<float> peak{0.f};
        explicit Track(int sr) : tape(sr) {}
    };

    int sr;
    std::vector<std::unique_ptr<Track>> tracks;
    Reverb reverb; TapeDelay delay;
    float masterVol = 0.9f, ret[2] = {0.35f, 0.7f};
    int loopSrc = 1;   // what the loop records: 0 microphone, 1 the track's sound

    bool playing = false;
    // tape start / stop: the loops speed up from standstill / slow down to it instead of cutting in and out
    double rate = 1.0; bool stopping = false; std::vector<float> rateArr; std::vector<double> cpArr;
    // scrubbing with a finger: the tape follows the target position with a smoothed speed (forward and backward), like a hand on the reel
    bool scrubActive = false, scrubTail = false; double scrubPos = 0, scrubV = 0; std::atomic<double> scrubTarget{0};
    float bpm = 120.f; int loopBars = 4;
    double pos = 0; int32_t loopSamples = 0;
    std::atomic<float> tapeSpeed{1.f}; double tapePos = 0;   // ONE tape pointer for every loop clip, so they never drift apart

    // free take
    bool freeRec = false, freeArmed = false; int freeTrack = 0; std::vector<float> freeBuf;

    // microphone sampler
    std::string dataDir, sampleDir;
    bool sampling = false, armedWait = false, waitForSound = true;
    std::vector<float> sampleBuf; std::string samplePath; bool pending = false;
    mutable std::mutex sampleMtx;
    std::atomic<float> micThr{0.04f};
    static constexpr int kLive = 2048;
    static constexpr int kFreeBins = 18500;   // 10 ms per bin, a little over 3 minutes
    std::atomic<float> freePk[kFreeBins]; std::atomic<int> freeN{0}; float freeAcc = 0; int freeCnt = 0;   // the first take, for the timeline while it is recorded
    std::atomic<float> livePk[kLive]; std::atomic<int> liveN{0}; size_t livePos = 0; float liveAcc = 0; int liveCnt = 0;

    // loop overview, refreshed in the background by the audio thread
    std::atomic<float> a_lpk[kLoopBins]; std::atomic<float> a_tpk[kTracks][kLoopBins]; int lpkBin = 0;

    // commands from other threads, run at the start of each block
    std::mutex cmdMtx; std::vector<std::function<void()>> cmds, run;
    // background worker: sample loading, offline stretch, file writes, freeing
    std::thread worker; std::mutex wMtx; std::condition_variable wCv; std::deque<std::function<void()>> jobs; bool wStop = false;

    // status mirror (the audio thread writes)
    std::atomic<double> a_pos{0};
    std::atomic<bool> a_playing{false}, a_free{false}, a_freeArmed{false}, a_pending{false};
    std::atomic<float> a_master{0.f}, a_freeSec{0.f}, a_sampleSec{0.f}, a_inPeak{0.f}, a_bpm{120.f};
    std::atomic<uint32_t> a_cpu{0}, a_clip_mask{0}, a_cliprec_mask{0};
    std::atomic<int> a_bars{4}, a_sampleState{0}, a_sampleTrack{0}, a_sampleVersion{0}, a_sampleFails{0};
    std::atomic<int32_t> a_loop{0};
    std::atomic<float> a_clipPos{0.f}, a_lfo[kTracks], a_scGain[kTracks], a_scLevel[kTracks];
    std::atomic<float> a_samplePlaybackPosition[kTracks];
    std::atomic<bool> a_samplePlaying[kTracks]{};
    std::atomic<int> a_voiceN[kTracks]; std::atomic<float> a_voicePos[kTracks][kVoiceMax], a_voiceLvl[kTracks][kVoiceMax];

    std::vector<float> bus, tmp, sendBus[2], wet;

    explicit Impl(int rate) : sr(rate), reverb(rate), delay(rate) {
        for (int i = 0; i < kTracks; i++) tracks.emplace_back(new Track(rate));
        bus.resize(kBlock * 2); tmp.resize(kBlock * 2); wet.resize(kBlock * 2); sendBus[0].resize(kBlock * 2); sendBus[1].resize(kBlock * 2);
        for (auto& a : a_lpk) a = 0.f;
        for (auto& r : a_tpk) for (auto& a : r) a = 0.f;
        for (auto& a : a_lfo) a = 0.f;
        for (auto& a : a_scGain) a = 1.f;
        for (auto& a : a_scLevel) a = 0.f;
        for (auto& a : a_voiceN) a = 0;
        for (auto& position : a_samplePlaybackPosition) position = -1.f;
        worker = std::thread([this] {
            for (;;) {
                std::function<void()> j;
                { std::unique_lock<std::mutex> l(wMtx); wCv.wait(l, [this] { return wStop || !jobs.empty(); }); if (wStop && jobs.empty()) return; j = std::move(jobs.front()); jobs.pop_front(); }
                j();
            }
        });
    }
    ~Impl() { { std::lock_guard<std::mutex> l(wMtx); wStop = true; } wCv.notify_all(); if (worker.joinable()) worker.join(); }
    void job(std::function<void()> f) { { std::lock_guard<std::mutex> l(wMtx); jobs.push_back(std::move(f)); } wCv.notify_one(); }
    void post(std::function<void()> f) { std::lock_guard<std::mutex> l(cmdMtx); cmds.push_back(std::move(f)); }
    template <class T> void bury(std::unique_ptr<T> p) { if (p) { auto sp = std::make_shared<std::unique_ptr<T>>(std::move(p)); job([sp] { sp->reset(); }); } }   // freed on the worker, not in the audio callback

    // ---- notes ----
    void releaseAll(Track& t) {
        std::vector<Arp::Ev> evs; t.arp.clear(evs);
        t.pending.clear();
        if (t.sampler) t.sampler->allOff();
    }
    void liveNote(int ti, int note, int vel) {
        Track& t = *tracks[ti];
        if (freeArmed && ti == freeTrack && loopSrc == 1 && vel > 0) { freeArmed = false; a_freeArmed = false; freeRec = true; playing = true; pos = 0; }   // the take starts with the first note
        if (t.arpOn) { if (vel) t.arp.noteOn(note); else t.arp.noteOff(note); }
        else t.pending.push_back({note, vel});
    }

    // ---- free take ----
    void freeStart(int track) {
        for (auto& t : tracks) { releaseAll(*t); t->clip.clear(); t->clip.shrink_to_fit(); t->clipHas = false; t->clipRec = false; }
        loopSamples = 0; a_loop = 0;
        freeArmed = true; a_freeArmed = true; freeRec = false; freeTrack = track;
        freeBuf.clear(); freeBuf.reserve((size_t)sr * 2 * 30);
        freeN = 0; freeAcc = 0; freeCnt = 0;
        pos = 0; playing = false;
    }
    void freeStop() {
        if (freeArmed) { freeArmed = false; a_freeArmed = false; return; }   // cancelled before any sound
        if (!freeRec) return;
        freeRec = false;
        const double len = pos;
        if (len < 0.25 * sr) { pos = 0; freeBuf.clear(); return; }   // too short: treat as cancelled
        // bars and tempo that fit the take (shown to the user; the loop length is exactly the take)
        const double barSec = 240.0 / bpm;
        int n = std::min(32, std::max(1, (int)std::lround(len / sr / barSec)));
        float nb = (float)(n * 240.0 * sr / len);
        while (nb > 300.f && n > 1) { n--; nb = (float)(n * 240.0 * sr / len); }
        while (nb < 30.f && n < 32) { n++; nb = (float)(n * 240.0 * sr / len); }
        bpm = std::min(300.f, std::max(30.f, nb)); a_bpm = bpm; loopBars = n; a_bars = n;
        loopSamples = (int32_t)std::lround(len); a_loop = loopSamples;
        Track& ft = *tracks[freeTrack];
        if (!freeBuf.empty()) { freeBuf.resize((size_t)loopSamples * 2, 0.f); ft.clip = std::move(freeBuf); ft.clipHas = true; }
        freeBuf = {};
        pos = 0; tapePos = 0;
    }
    void clearIfEmpty() {
        for (auto& t : tracks) if (t->clipHas) return;
        loopSamples = 0; a_loop = 0; pos = 0; tapePos = 0;
    }

    // ---- samples ----
    static std::string baseName(const std::string& p) { size_t s = p.find_last_of("/\\"); return p.substr(s == std::string::npos ? 0 : s + 1); }
    void installNew(const std::string& path, int track, bool kit) {
        auto sm = std::make_unique<Sampler>(sr);
        if (!sm->load(path)) { a_sampleFails++; a_sampleState = 0; return; }
        auto holder = std::make_shared<std::unique_ptr<Sampler>>(std::move(sm));
        post([this, holder, track, kit] {
            Track& t = *tracks[track];
            releaseAll(t);
            std::swap(t.sampler, *holder);
            applyModeParams(t);
            { std::lock_guard<std::mutex> l(t.infoMtx); t.label = t.sampler->label(); t.peaks = t.sampler->peaks(); t.orig = t.sampler->original(); }
            (void)kit;
            bury(std::move(*holder));
            a_sampleTrack = track; a_sampleVersion++; a_sampleState = 0;
            startProcess(track);   // the stretch / pitch that was set for this track applies to the new sample too
        });
    }
    // audio thread: hand the mode parameters of a track to its sampler and publish the slices for the UI
    void applyModeParams(Track& t) {
        if (!t.sampler) return;
        t.sampler->setSliceThreshold(t.sliceThr); t.sampler->setKitPitch(t.kitSemis); t.sampler->setGrain(t.grainN, t.grainScatter); t.sampler->setPaul(t.paulStretch, t.paulWidth);
        auto f = t.sampler->sliceFractions();
        std::lock_guard<std::mutex> l(t.infoMtx); t.slices = std::move(f);
    }
    // audio thread: build the stretched copy of the track's range on the worker, then swap it in
    void startProcess(int ti) {
        Track& t = *tracks[ti];
        if (!t.sampler) return;
        const uint32_t gen = ++t.gen;
        auto orig = t.sampler->original();
        const float a = t.rangeA, b = t.rangeB, speed = t.speed, semis = t.semis;
        if (std::fabs(speed - 1.f) < 0.005f && std::fabs(semis) < 0.005f) { t.sampler->setProcessed(nullptr, 0.f, 1.f); return; }
        job([this, ti, gen, orig, a, b, speed, semis] {
            const int f0 = (int)(a * orig->frames), f1 = std::max(f0 + 64, (int)(b * orig->frames));
            std::vector<float> seg(orig->d.begin() + 2 * (size_t)f0, orig->d.begin() + 2 * (size_t)std::min(f1, orig->frames));
            auto out = std::make_shared<SampleBuf>();
            out->d = stretchPitch(seg, orig->sr, speed, semis); out->frames = (int)(out->d.size() / 2); out->sr = orig->sr;
            post([this, ti, gen, orig, a, b, out] {
                Track& t = *tracks[ti];
                if (t.gen == gen && t.sampler && t.sampler->original() == orig) t.sampler->setProcessed(out, a, b);
            });
        });
    }

    // ---- microphone sampler ----
    void liveReset() { liveN = 0; livePos = 0; liveAcc = 0; liveCnt = 0; }
    void liveFeed() {
        const int bin = sr / 20;
        for (; livePos < sampleBuf.size(); livePos++) {
            liveAcc = std::max(liveAcc, std::fabs(sampleBuf[livePos]));
            if (++liveCnt >= bin && liveN < kLive) { livePk[liveN.load()].store(liveAcc); liveN++; liveAcc = 0; liveCnt = 0; }
        }
    }
    // mono capture; while waiting for sound only a short look-ahead is kept, and the take starts when the level crosses the threshold
    void captureMono(const float* x, int n) {
        float pk = 0;
        for (int i = 0; i < n; i++) { const float m = 0.5f * (x[2 * i] + x[2 * i + 1]); sampleBuf.push_back(m); pk = std::max(pk, std::fabs(m)); }
        if (armedWait) {
            if (pk > micThr.load()) { armedWait = false; sampling = true; a_sampleState = 1; }
            else if (sampleBuf.size() > 2048) sampleBuf.erase(sampleBuf.begin(), sampleBuf.end() - 2048);
        }
        if (sampling) liveFeed();
    }
    // worker thread: trim, normalise, write the WAV; the result becomes the pending sample
    void finishSample(std::vector<float> st /*interleaved stereo*/) {
        const size_t frames = st.size() / 2;
        size_t a = 0, b = frames;
        while (a < frames && std::fabs(st[2 * a]) < 0.02f && std::fabs(st[2 * a + 1]) < 0.02f) a++;
        while (b > a && std::fabs(st[2 * (b - 1)]) < 0.01f && std::fabs(st[2 * (b - 1) + 1]) < 0.01f) b--;
        a = a > (size_t)(sr / 200) ? a - sr / 200 : 0; b = std::min(frames, b + (size_t)sr / 50);
        if (b <= a + (size_t)(sr / 50)) { a_sampleState = 0; return; }
        std::vector<float> o(st.begin() + 2 * a, st.begin() + 2 * b);
        float pk = 0; for (float v : o) pk = std::max(pk, std::fabs(v));
        if (pk > 1e-4f) { const float g = 0.9f / pk; for (float& v : o) v *= g; }
        const size_t fade = std::min<size_t>(o.size() / 4, (size_t)sr / 200 * 2);
        for (size_t i = 0; i < fade; i += 2) { const float k = (float)i / fade; o[i] *= k; o[i + 1] *= k; o[o.size() - 2 - i] *= k; o[o.size() - 1 - i] *= k; }
        char name[64]; snprintf(name, sizeof name, "/sample_%lld.wav", (long long)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
        const std::string path = (dataDir.empty() ? "." : dataDir) + name;
        writeWav16(path, o, sr);
        { std::lock_guard<std::mutex> l(sampleMtx); samplePath = path; pending = true; a_pending = true; }
        a_sampleState = 0;
    }

    // ---- loop overview ----
    void updateLoopPeaks() {
        const int32_t L = loopSamples;
        for (int r = 0; r < 8; r++) {
            const int b = lpkBin; lpkBin = (lpkBin + 1) % kLoopBins;
            if (L <= 0) { a_lpk[b].store(0.f); for (int t = 0; t < kTracks; t++) a_tpk[t][b].store(0.f); continue; }
            const int32_t a = (int32_t)((int64_t)b * L / kLoopBins), e = (int32_t)((int64_t)(b + 1) * L / kLoopBins), step = std::max<int32_t>(1, (e - a) / 24);
            float mix = 0, tp[kTracks] = {};
            for (int32_t f = a; f < e; f += step) {
                float sum = 0;
                for (int t = 0; t < kTracks; t++) {
                    const auto& c = tracks[(size_t)t]->clip;
                    if (!tracks[(size_t)t]->clipHas || c.size() != (size_t)L * 2) continue;
                    const float v = 0.5f * (c[(size_t)2 * f] + c[(size_t)2 * f + 1]); sum += v; tp[t] = std::max(tp[t], std::fabs(v));
                }
                mix = std::max(mix, std::fabs(sum));
            }
            a_lpk[b].store(mix); for (int t = 0; t < kTracks; t++) a_tpk[t][b].store(tp[t]);
        }
    }

    // ---- one block of `n` frames ----
    void block(float* out, const float* in, int n) {
        std::fill(out, out + n * 2, 0.f);
        for (auto& s : sendBus) std::fill(s.begin(), s.begin() + n * 2, 0.f);
        const size_t freeBase = freeBuf.size();
        if (freeRec && loopSrc == 1) freeBuf.resize(freeBase + (size_t)n * 2, 0.f);   // the track's sound is added below
        if (in) {
            float ip = 0;
            for (int i = 0; i < n * 2; i++) ip = std::max(ip, std::fabs(in[i]));
            a_inPeak.store(std::max(ip, a_inPeak.load() * 0.9f));
            if (freeArmed && loopSrc == 0 && ip > micThr.load()) { freeArmed = false; a_freeArmed = false; freeRec = true; playing = true; pos = 0; }   // first sound: the take starts
            if (freeRec && loopSrc == 0) freeBuf.insert(freeBuf.end(), in, in + n * 2);
            if (sampling || armedWait) captureMono(in, n);
        }
        const int32_t p0 = (int32_t)pos;
        const bool tl = playing && !freeRec && loopSamples > 0;
        updateLoopPeaks();
        const double spd = tapeSpeed.load();
        if (!playing) { rate = 1.0; stopping = false; }
        bool ramp = false; double rateSum = n, tapeEnd = tapePos;
        const bool scrubbing = (scrubActive || scrubTail) && loopSamples > 0 && !freeRec;
        if (scrubActive && (loopSamples <= 0 || freeRec)) scrubActive = false;
        if (scrubbing) {   // the read position is driven by the finger: speed follows (target - position), smoothed, so there are no jumps and no clicks
            ramp = true; rateSum = 0;
            if ((int)rateArr.size() < n) { rateArr.resize((size_t)n); cpArr.resize((size_t)n); }
            const double L = (double)loopSamples, follow = 1.0 / (0.07 * sr), smooth = 1.0 - std::exp(-1.0 / (0.012 * sr));
            const double run = (playing && !stopping) ? spd : 0.0;   // after the finger lifts the tape goes back to the transport speed (or stands still)
            for (int i = 0; i < n; i++) {
                double want = scrubActive ? std::max(-6.0, std::min(6.0, (scrubTarget.load() - scrubPos) * follow)) : run;
                if (scrubActive && std::fabs(scrubTarget.load() - scrubPos) < 2.0) want = 0.0;
                scrubV += (want - scrubV) * smooth;
                cpArr[(size_t)i] = scrubPos;
                rateArr[(size_t)i] = (float)std::min(1.0, std::sqrt(std::fabs(scrubV)));   // standing tape is silent, a slow one quiet
                scrubPos += scrubV;
                if (scrubActive) scrubPos = std::max(0.0, std::min(L - 1.0, scrubPos)); else { scrubPos = std::fmod(scrubPos, L); if (scrubPos < 0) scrubPos += L; }
            }
            tapeEnd = scrubPos;
            if (!scrubActive && std::fabs(scrubV - run) < 0.01) { scrubTail = false; scrubV = 0; rate = 1.0; if (!playing) { rateArr[(size_t)n - 1] = 0.f; } }
        } else if (tl && (stopping || rate < 1.0)) {   // the tape runs up to speed / down to standstill: a per-sample rate and read position
            ramp = true; rateSum = 0;
            if ((int)rateArr.size() < n) { rateArr.resize((size_t)n); cpArr.resize((size_t)n); }
            const double step = stopping ? 1.0 / (0.7 * sr) : 1.0 / (0.45 * sr);
            double acc = tapePos;
            for (int i = 0; i < n; i++) {
                rate = stopping ? std::max(0.0, rate - step) : std::min(1.0, rate + step);
                rateArr[(size_t)i] = (float)rate; rateSum += rate; cpArr[(size_t)i] = acc;
                acc = std::fmod(acc + spd * rate, (double)loopSamples);
            }
            tapeEnd = acc;
        }
        const bool locked = !ramp && std::fabs(spd - 1.0) < 0.01;
        const double tb = loopSamples > 0 ? (locked ? (double)(p0 % loopSamples) : tapePos) : 0.0;
        if (loopSamples > 0) tapePos = ramp ? tapeEnd : !tl ? (double)(p0 % loopSamples) : locked ? (double)((p0 + n) % loopSamples) : std::fmod(tb + n * spd, (double)loopSamples);
        bool anyEvents;
        std::vector<Arp::Ev> evs;
        for (int ti = 0; ti < kTracks; ti++) {
            Track& t = *tracks[(size_t)ti];
            if (!t.sampler && !t.clipHas && !t.clipRec && t.pending.empty()) { t.peak.store(t.peak.load() * 0.9f); t.scEnv *= 0.8f; t.scGain = 1.f; a_voiceN[ti].store(0); a_samplePlaying[ti].store(false); a_samplePlaybackPosition[ti].store(-1.f); continue; }
            std::fill(bus.begin(), bus.begin() + n * 2, 0.f);
            // LFO: one value per block (about 170 Hz)
            float lfoGain = 1.f, lfoPan = 0.f, bend = 0.f; bool filterOn = false;
            if (t.lfo.depth > 0.001f) {
                t.lfoPhase += t.lfo.rate * n / sr; if (t.lfoPhase >= 1.f) { t.lfoPhase -= std::floor(t.lfoPhase); t.lfoSH = (float)(rand() % 2001 - 1000) / 1000.f; }
                const float ph = t.lfoPhase;
                const float v = t.lfo.shape == 0 ? std::sin(2.f * kPi * ph) : t.lfo.shape == 1 ? (ph < 0.5f ? 4 * ph - 1 : 3 - 4 * ph) : t.lfo.shape == 2 ? (ph < 0.5f ? 1.f : -1.f) : t.lfoSH;
                t.lfoVal = v;
                if (t.lfo.target == 0) bend = v * t.lfo.depth * t.lfo.depth * 12.f;   // +-12 semitones at full depth
                else if (t.lfo.target == 1) { filterOn = true; t.filt.set(20.f * std::pow(1000.f, clampf(t.lfo.base + 0.5f * v * t.lfo.depth, 0.f, 1.f)), (float)sr); }
                else if (t.lfo.target == 2) lfoGain = 1.f - t.lfo.depth * (0.5f - 0.5f * v);
                else lfoPan = v * t.lfo.depth;
            } else t.lfoVal = 0.f;
            if (filterOn != t.filtOn) { t.filtOn = filterOn; t.filt.reset(); }
            a_lfo[ti].store(t.lfoVal);
            a_scGain[ti].store(t.scGain); a_scLevel[ti].store(t.scEnv);
            // notes of the block: live ones at the start, the arpeggiator's with sample accurate offsets
            evs.clear();
            for (auto& nt : t.pending) evs.push_back({0, nt.note, nt.vel});
            t.pending.clear();
            if (t.arpOn) t.arp.run(n, bpm, sr, evs);
            std::stable_sort(evs.begin(), evs.end(), [](const Arp::Ev& a, const Arp::Ev& b) { return a.offset < b.offset; });
            if (t.sampler) {
                t.sampler->setBend(bend);
                int cur = 0;
                for (auto& e : evs) {
                    const int off = std::min(n, std::max(cur, e.offset));
                    if (off > cur) { t.sampler->render(bus.data() + 2 * cur, off - cur); cur = off; }
                    if (e.vel) t.sampler->noteOn(e.note, e.vel); else t.sampler->noteOff(e.note);
                }
                if (cur < n) t.sampler->render(bus.data() + 2 * cur, n - cur);
                float vp[kVoiceMax], vl[kVoiceMax]; const int vn = t.sampler->voicePositions(vp, kVoiceMax, vl);
                for (int i = 0; i < vn; i++) { a_voicePos[ti][i].store(vp[i]); a_voiceLvl[ti][i].store(vl[i]); }
                a_voiceN[ti].store(vn);
            } else a_voiceN[ti].store(0);
            a_samplePlaying[ti].store(t.sampler && t.sampler->transportPlaybackActive());
            a_samplePlaybackPosition[ti].store(t.sampler ? t.sampler->transportPlaybackPosition() : -1.f);
            if (t.filtOn) for (int i = 0; i < n; i++) { bus[2 * i] = t.filt.process(0, bus[2 * i]); bus[2 * i + 1] = t.filt.process(1, bus[2 * i + 1]); }
            // the sound of the track itself (before the loop is added), for the free take
            if (freeRec && loopSrc == 1 && ti == freeTrack) for (int i = 0; i < n * 2; i++) freeBuf[freeBase + (size_t)i] += bus[(size_t)i];
            if (tl || scrubbing) {
                for (int i = 0; i < n; i++) {
                    const int32_t k0 = (p0 + i) % loopSamples;
                    const double cp = ramp ? cpArr[(size_t)i] : locked ? (double)k0 : std::fmod(tb + i * spd, (double)loopSamples);
                    const float lg = ramp ? rateArr[(size_t)i] : 1.f;   // while the tape starts / stops its level follows the speed
                    const float src0 = bus[2 * i], src1 = bus[2 * i + 1];
                    const int32_t k = (int32_t)cp % loopSamples;
                    if (t.clipHas) {
                        auto& c = t.clip;
                        if (locked) { bus[2 * i] += c[(size_t)2 * k]; bus[2 * i + 1] += c[(size_t)2 * k + 1]; }
                        else {   // tape speed: its own read pointer, linear interpolation
                            const int32_t k1 = (k + 1) % loopSamples; const float fr = (float)(cp - std::floor(cp));
                            bus[2 * i] += (c[(size_t)2 * k] + (c[(size_t)2 * k1] - c[(size_t)2 * k]) * fr) * lg; bus[2 * i + 1] += (c[(size_t)2 * k + 1] + (c[(size_t)2 * k1 + 1] - c[(size_t)2 * k + 1]) * fr) * lg;
                        }
                    }
                    if (t.clipRec && !ramp) {
                        if (t.clip.size() != (size_t)loopSamples * 2) t.clip.assign((size_t)loopSamples * 2, 0.f);
                        auto& c = t.clip;
                        // recording works at any tape speed, as the head of a tape machine: the input lands on the moving tape position.
                        // Slower than 1x the input is spread over the two neighbouring cells weighted by the speed (no pile-up);
                        // faster than 1x the cells the tape skipped since the last sample are filled by interpolating the input (no holes).
                        const float il = loopSrc == 0 && in ? in[2 * i] : loopSrc == 1 ? src0 : 0.f, ir = loopSrc == 0 && in ? in[2 * i + 1] : loopSrc == 1 ? src1 : 0.f;
                        if (locked) { c[(size_t)2 * k] += il; c[(size_t)2 * k + 1] += ir; t.recPrevOk = false; }
                        else if (spd >= 1.0) {
                            if (t.recPrevOk) {
                                const double p = t.recPrevCp; double cur = cp; if (cur < p) cur += (double)loopSamples;
                                for (int64_t cell = (int64_t)std::floor(p) + 1; cell <= (int64_t)std::floor(cur); cell++) {
                                    const float u = (float)((cell - p) / (cur - p)); const size_t idx = (size_t)(cell % loopSamples);
                                    c[2 * idx] += t.recPrevL + (il - t.recPrevL) * u; c[2 * idx + 1] += t.recPrevR + (ir - t.recPrevR) * u;
                                }
                            } else { c[(size_t)2 * k] += il; c[(size_t)2 * k + 1] += ir; }
                            t.recPrevCp = cp; t.recPrevL = il; t.recPrevR = ir; t.recPrevOk = true;
                        } else {
                            const float fr = (float)(cp - std::floor(cp)), w = (float)spd; const size_t k1 = (size_t)((k + 1) % loopSamples);
                            c[(size_t)2 * k] += il * w * (1.f - fr); c[(size_t)2 * k + 1] += ir * w * (1.f - fr);
                            c[2 * k1] += il * w * fr; c[2 * k1 + 1] += ir * w * fr;
                            t.recPrevOk = false;
                        }
                        t.clipHas = true;
                    } else t.recPrevOk = false;
                }
            }
            t.tape.process(bus.data(), n);
            {   // this track's level for the others (peak with a ~120 ms release) ...
                float bp = 0.f; for (int i = 0; i < n * 2; i++) bp = std::max(bp, std::fabs(bus[(size_t)i]));
                t.scEnv = std::max(bp, t.scEnv * std::exp(-(float)n / (0.12f * sr)));
            }
            // ... and the gain the sidechain asks for: over the threshold the level is pulled down by (over)(1 - 1/ratio) dB; fast attack, slow release
            float scTarget = 1.f;
            if (t.scSrc >= 0 && t.scSrc != ti && t.scRatio > 1.01f) {
                const float lvDb = 20.f * std::log10(std::max(1e-5f, tracks[(size_t)t.scSrc]->scEnv)), over = lvDb - t.scThrDb;
                if (over > 0.f) scTarget = std::pow(10.f, -over * (1.f - 1.f / t.scRatio) / 20.f);
            }
            const float scFrom = t.scGain; t.scGain += (scTarget - t.scGain) * (scTarget < t.scGain ? 0.7f : 0.08f);
            const float g = t.vol * lfoGain;
            const float ang = (clampf(t.pan + lfoPan, -1.f, 1.f) * 0.5f + 0.5f) * 1.5707963f;
            const float gl = g * std::cos(ang) * 1.4142f, gr = g * std::sin(ang) * 1.4142f;
            float pk = 0.f;
            for (int i = 0; i < n; i++) {
                const float sc = scFrom + (t.scGain - scFrom) * (float)(i + 1) / n;
                const float l = bus[2 * i] * gl * sc, r = bus[2 * i + 1] * gr * sc;
                out[2 * i] += l; out[2 * i + 1] += r;
                for (int sd = 0; sd < 2; sd++) if (t.send[sd] > 0.f) { sendBus[sd][2 * i] += l * t.send[sd]; sendBus[sd][2 * i + 1] += r * t.send[sd]; }
                pk = std::max(pk, std::max(std::fabs(l), std::fabs(r)));
            }
            t.peak.store(std::max(pk, t.peak.load() * 0.92f));
        }
        (void)anyEvents;
        if (freeRec && freeBuf.size() >= freeBase + (size_t)n * 2) {
            const int bin = std::max(1, sr / 100);
            for (int i = 0; i < n; i++) {
                freeAcc = std::max(freeAcc, std::max(std::fabs(freeBuf[freeBase + 2 * (size_t)i]), std::fabs(freeBuf[freeBase + 2 * (size_t)i + 1])));
                if (++freeCnt >= bin && freeN < kFreeBins) { freePk[freeN.load()].store(freeAcc); freeN++; freeAcc = 0; freeCnt = 0; }
            }
        }
        a_clipPos.store(loopSamples > 0 ? (float)(tapePos / loopSamples) : 0.f);
        reverb.process(sendBus[0].data(), wet.data(), n);
        for (int i = 0; i < n * 2; i++) out[i] += wet[(size_t)i] * ret[0];
        delay.process(sendBus[1].data(), wet.data(), n);
        for (int i = 0; i < n * 2; i++) out[i] += wet[(size_t)i] * ret[1];
        float mp = 0.f;
        for (int i = 0; i < n * 2; i++) { const float v = std::tanh(out[i] * masterVol); out[i] = v; mp = std::max(mp, std::fabs(v)); }
        a_master.store(std::max(mp, a_master.load() * 0.92f));
        if (playing) {
            pos += rateSum;
            if (freeRec) a_freeSec = (float)(pos / sr);
            else if (loopSamples > 0 && pos >= loopSamples) pos -= loopSamples;
        }
        if (scrubbing) { pos = tapeEnd; }
        if (stopping && !scrubbing && (rate <= 0.0 || !tl)) { playing = false; stopping = false; rate = 1.0; for (auto& t : tracks) releaseAll(*t); }
        if (sampling) a_sampleSec = (float)sampleBuf.size() / sr;
    }
};

Session::Session(int sampleRate) : d(new Impl(sampleRate)) {}
Session::~Session() = default;

void Session::process(float* out, const float* in, int frames) {
    const auto t0 = std::chrono::steady_clock::now();
    {
        std::unique_lock<std::mutex> l(d->cmdMtx, std::try_to_lock);
        if (l.owns_lock() && !d->cmds.empty()) d->run.swap(d->cmds);
    }
    for (auto& f : d->run) f();
    d->run.clear();
    for (int done = 0; done < frames; done += kBlock) {
        const int n = std::min(kBlock, frames - done);
        d->block(out + 2 * done, in ? in + 2 * done : nullptr, n);
    }
    d->a_pos = d->pos; d->a_playing = d->playing && !d->stopping; d->a_free = d->freeRec;
    uint32_t cm = 0, rm = 0;
    for (int i = 0; i < kTracks; i++) { cm |= (uint32_t)d->tracks[(size_t)i]->clipHas << i; rm |= (uint32_t)d->tracks[(size_t)i]->clipRec << i; }
    d->a_clip_mask = cm; d->a_cliprec_mask = rm;
    const double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count(), budget = frames * 1e6 / d->sr;
    d->a_cpu = (d->a_cpu.load() * 7 + (uint32_t)(1000.0 * us / budget)) / 8;
}

// ---- transport and notes ----
void Session::play(bool on) {
    d->post([this, on] {
        if (!on) {
            if (d->freeRec || d->freeArmed) d->freeStop();
            if (d->playing) d->stopping = true;   // the tape slows down to standstill (block() ends it: playing = false, notes released)
        } else {
            d->stopping = false;
            if (!d->playing) { d->playing = true; d->rate = d->loopSamples > 0 ? 0.0 : 1.0; }   // the tape runs up from standstill
        }
    });
}
void Session::stopAndRewind() {
    d->post([this] {
        if (d->freeRec || d->freeArmed) d->freeStop();
        d->playing = d->stopping = d->scrubActive = d->scrubTail = false;
        d->pos = d->tapePos = d->scrubPos = d->scrubV = 0;
        d->rate = 1.0;
        for (auto& track : d->tracks) d->releaseAll(*track);
    });
}
void Session::noteOn(int t, int note, int vel) { if (t >= 0 && t < kTracks) d->post([=] { d->liveNote(t, note, std::max(1, vel)); }); }
void Session::noteOff(int t, int note) { if (t >= 0 && t < kTracks) d->post([=] { d->liveNote(t, note, 0); }); }

void Session::stopSamplePlayback(int track) {
    if (track < 0 || track >= kTracks) return;
    d->post([this, track] {
        auto& sampler = d->tracks[(size_t)track]->sampler;
        if (sampler) sampler->allOff();
    });
}

void Session::setSamplePlayback(int track, bool play) {
    if (track < 0 || track >= kTracks) return;
    d->post([this, track, play] {
        auto& sampler = d->tracks[(size_t)track]->sampler;
        if (sampler) sampler->setTransportPlayback(play);
    });
}
void Session::seekSamplePlayback(int track, float position) {
    if (track < 0 || track >= kTracks) return;
    d->post([this, track, position] {
        auto& sampler = d->tracks[(size_t)track]->sampler;
        if (sampler) sampler->seekTransportPlayback(position);
    });
}

void Session::clearSamplePlayback(int track) {
    if (track < 0 || track >= kTracks) return;
    d->post([this, track] {
        auto& sampler = d->tracks[(size_t)track]->sampler;
        if (sampler) sampler->clearTransportPlayback();
    });
}

// ---- sampler ----
void Session::loadSamplePath(const std::string& path, bool kit, int track) {
    if (track < 0 || track >= kTracks || !std::filesystem::exists(path)) return;
    d->a_sampleState = 2;
    d->job([this, path, track, kit] { d->installNew(path, track, kit); });
}
void Session::setMode(int t, int m) { if (t >= 0 && t < kTracks) d->post([=] { if (d->tracks[(size_t)t]->sampler) d->tracks[(size_t)t]->sampler->setMode(m); }); }
void Session::setEnv(int t, float a, float dc, float s, float r) { if (t >= 0 && t < kTracks) d->post([=] { if (d->tracks[(size_t)t]->sampler) d->tracks[(size_t)t]->sampler->setEnv(a, dc, s, r); }); }
void Session::setRoot(int t, float note) { if (t >= 0 && t < kTracks) d->post([=] { if (d->tracks[(size_t)t]->sampler) d->tracks[(size_t)t]->sampler->setRoot(note); }); }
float Session::detectRoot(int t) const {
    if (t < 0 || t >= kTracks) return -1.f;
    std::shared_ptr<const SampleBuf> o; { std::lock_guard<std::mutex> l(d->tracks[(size_t)t]->infoMtx); o = d->tracks[(size_t)t]->orig; }
    if (!o) return -1.f;
    const float hz = detectPitchHz(*o);
    return hz > 20.f ? 69.f + 12.f * std::log2(hz / 440.f) : -1.f;
}
void Session::setSampleRange(int t, float a, float b) {
    if (t < 0 || t >= kTracks) return;
    d->post([=] { auto& tr = *d->tracks[(size_t)t]; tr.rangeA = clampf(a, 0.f, 1.f); tr.rangeB = clampf(b, 0.f, 1.f); if (tr.sampler) { tr.sampler->setRange(a, b); d->applyModeParams(tr); } });
}
void Session::setSliceThreshold(int t, float v) { if (t >= 0 && t < kTracks) d->post([=] { auto& tr = *d->tracks[(size_t)t]; tr.sliceThr = clampf(v, 0.f, 1.f); d->applyModeParams(tr); }); }
void Session::setKitPitch(int t, float s) { if (t >= 0 && t < kTracks) d->post([=] { auto& tr = *d->tracks[(size_t)t]; tr.kitSemis = s; d->applyModeParams(tr); }); }
void Session::setGrain(int t, int n, float sc) { if (t >= 0 && t < kTracks) d->post([=] { auto& tr = *d->tracks[(size_t)t]; tr.grainN = n; tr.grainScatter = sc; d->applyModeParams(tr); }); }
void Session::setPaul(int t, float st, float w) { if (t >= 0 && t < kTracks) d->post([=] { auto& tr = *d->tracks[(size_t)t]; tr.paulStretch = st; tr.paulWidth = w; d->applyModeParams(tr); }); }
std::vector<float> Session::sliceFractions(int t) const {
    if (t < 0 || t >= kTracks) return {};
    const auto& tr = *d->tracks[(size_t)t];
    std::lock_guard<std::mutex> l(tr.infoMtx);
    return tr.slices;
}
void Session::setStretch(int t, float speed, float semis, bool commit) {
    if (t < 0 || t >= kTracks) return;
    d->post([=] { auto& tr = *d->tracks[(size_t)t]; tr.speed = speed; tr.semis = semis; if (commit) d->startProcess(t); });
}
void Session::setLfo(int t, const Lfo& l) { if (t >= 0 && t < kTracks) d->post([=] { d->tracks[(size_t)t]->lfo = l; }); }
void Session::setArp(int t, bool on, int rate, int pattern, int octaves, float gate) {
    if (t < 0 || t >= kTracks) return;
    d->post([=] {
        auto& tr = *d->tracks[(size_t)t];
        tr.arp.setup(rate, pattern, octaves, gate);
        if (on != tr.arpOn) { d->releaseAll(tr); tr.arpOn = on; }
    });
}
void Session::setTape(int t, float sat, float tone, float wobble, float hiss, float mix, float bits) {
    if (t >= 0 && t < kTracks) d->post([=] { d->tracks[(size_t)t]->tape.setParams(sat, tone, wobble, hiss, mix, bits); });
}

// ---- mixer ----
void Session::setVolume(int t, float v) { if (t >= 0 && t < kTracks) d->post([=] { d->tracks[(size_t)t]->vol = clampf(v, 0.f, 1.5f); }); }
void Session::setPan(int t, float p) { if (t >= 0 && t < kTracks) d->post([=] { d->tracks[(size_t)t]->pan = clampf(p, -1.f, 1.f); }); }
void Session::setSidechain(int t, int src, float thresholdDb, float ratio) {
    if (t >= 0 && t < kTracks) d->post([=] { auto& tr = *d->tracks[(size_t)t]; tr.scSrc = (src >= 0 && src < kTracks) ? src : -1; tr.scThrDb = clampf(thresholdDb, -60.f, 0.f); tr.scRatio = clampf(ratio, 1.f, 40.f); if (tr.scSrc < 0) tr.scGain = 1.f; });
}
void Session::setSend(int t, int w, float l) { if (t >= 0 && t < kTracks && (w == 0 || w == 1)) d->post([=] { d->tracks[(size_t)t]->send[w] = clampf(l, 0.f, 1.f); }); }
void Session::setMasterVolume(float v) { d->post([=] { d->masterVol = clampf(v, 0.f, 1.5f); }); }
void Session::setReverb(float size) { d->post([=] { d->reverb.setSize(size); }); }
void Session::setDelay(float sec, float fb) { d->post([=] { d->delay.setTime(sec); d->delay.setFeedback(fb); }); }
void Session::setRetLevel(int w, float v) { d->post([=] { d->ret[w & 1] = clampf(v, 0.f, 1.5f); }); }

// ---- looper ----
void Session::freeRecord(int t, bool on) { if (t >= 0 && t < kTracks) d->post([=] { if (on) d->freeStart(t); else d->freeStop(); }); }
void Session::clipRecord(int t, bool on) { if (t >= 0 && t < kTracks) d->post([=] { d->tracks[(size_t)t]->clipRec = on; }); }
void Session::clipClear(int t) {
    if (t >= 0 && t < kTracks) d->post([=] { auto& tr = *d->tracks[(size_t)t]; tr.clipRec = false; tr.clip.clear(); tr.clipHas = false; d->clearIfEmpty(); });
}
void Session::clipClearAll() {
    d->post([this] { for (auto& t : d->tracks) { t->clipRec = false; t->clip.clear(); t->clipHas = false; } d->clearIfEmpty(); });
}
void Session::loopDouble() {
    d->post([this] {
        const int32_t L = d->loopSamples;
        if (L <= 0 || (int64_t)L * 2 > (int64_t)d->sr * 180) return;
        for (auto& t : d->tracks) {
            if (t->clipHas && t->clip.size() == (size_t)L * 2) { auto& c = t->clip; c.resize((size_t)L * 4); std::copy(c.begin(), c.begin() + (size_t)L * 2, c.begin() + (size_t)L * 2); }
            else { t->clip.clear(); t->clipHas = false; }
        }
        d->loopSamples = L * 2; d->a_loop = d->loopSamples;
        d->loopBars = std::min(32, d->loopBars * 2); d->a_bars = d->loopBars;
    });
}
void Session::loopHalve() {
    d->post([this] {
        const int32_t L = d->loopSamples, h = L / 2;
        if (L <= 0 || h < d->sr / 4) return;
        for (auto& t : d->tracks) if (t->clipHas && t->clip.size() == (size_t)L * 2) t->clip.resize((size_t)h * 2);
        d->loopSamples = h; d->a_loop = h;
        d->loopBars = std::max(1, d->loopBars / 2); d->a_bars = d->loopBars;
        if (d->pos >= h) d->pos = std::fmod(d->pos, (double)h);
        if (d->tapePos >= h) d->tapePos = std::fmod(d->tapePos, (double)h);
    });
}
void Session::scrubBegin(float f) {
    d->post([this, f] {
        if (d->loopSamples <= 0 || d->freeRec) return;
        if (!d->scrubActive && !d->scrubTail) { d->scrubPos = d->tapePos; d->scrubV = d->playing && !d->stopping ? d->rate * d->tapeSpeed.load() : 0.0; }
        if (d->stopping) { d->playing = false; d->stopping = false; }
        d->scrubActive = true; d->scrubTail = false; d->scrubTarget.store(clampf(f, 0.f, 0.9999f) * d->loopSamples);
    });
}
void Session::scrubMove(float f) { d->scrubTarget.store((double)clampf(f, 0.f, 0.9999f) * d->a_loop.load()); }
void Session::scrubEnd() { d->post([this] { if (d->scrubActive) { d->scrubActive = false; d->scrubTail = true; } }); }
void Session::seek(float f) {
    d->post([this, f] {
        if (d->loopSamples <= 0 || d->freeRec) return;
        const double p = clampf(f, 0.f, 0.9999f) * d->loopSamples;
        d->pos = p; d->tapePos = p;
    });
}
void Session::setLoopSpeed(float v) { d->tapeSpeed.store(clampf(v, 0.25f, 2.f)); }
void Session::setLoopSource(int src) { d->post([=] { d->loopSrc = src ? 1 : 0; }); }
bool Session::saveClip(int t) {
    if (t < 0 || t >= kTracks || !d->tracks[(size_t)t]->clipHas) return false;
    std::vector<float> c = d->tracks[(size_t)t]->clip;   // a copy, written on the worker
    d->job([this, c = std::move(c)]() mutable { d->finishSample(std::move(c)); d->a_pending = false; });
    return true;
}
int Session::loopPeaks(int track, float* out, int maxBins) const {
    const int n = std::min(maxBins, kLoopBins);
    for (int i = 0; i < n; i++) out[i] = track < 0 ? d->a_lpk[i].load() : d->a_tpk[std::min(track, kTracks - 1)][i].load();
    return d->a_loop.load() > 0 ? n : 0;
}

// ---- microphone sampling ----
void Session::setMicThreshold(float v) { d->micThr.store(clampf(v, 0.005f, 0.5f)); }
void Session::recorderWait(bool w) { d->post([this, w] { if (!d->sampling && !d->armedWait) d->waitForSound = w; }); }
void Session::recorderStart() {
    d->post([this] {
        if (d->sampling || d->armedWait) return;
        d->sampleBuf.clear(); d->sampleBuf.reserve((size_t)d->sr * 30); d->a_sampleSec = 0; d->liveReset();
        if (d->waitForSound) { d->armedWait = true; d->a_sampleState = 3; } else { d->sampling = true; d->a_sampleState = 1; }
    });
}
void Session::recorderStop() {
    d->post([this] {
        if (d->armedWait) { d->armedWait = false; d->sampleBuf.clear(); d->a_sampleState = 0; return; }
        if (!d->sampling) return;
        d->sampling = false; d->a_sampleState = 2;
        std::vector<float> st(d->sampleBuf.size() * 2);
        for (size_t i = 0; i < d->sampleBuf.size(); i++) st[2 * i] = st[2 * i + 1] = d->sampleBuf[i];
        d->sampleBuf.clear();
        d->job([this, st = std::move(st)]() mutable { d->finishSample(std::move(st)); });
    });
}
void Session::recorderDismiss() { std::lock_guard<std::mutex> l(d->sampleMtx); d->pending = false; d->a_pending = false; }
std::string Session::lastSamplePath() const { std::lock_guard<std::mutex> l(d->sampleMtx); return d->samplePath; }
int Session::freePeaks(float* out, int maxBins) const {
    const int n = std::min(maxBins, d->freeN.load());
    for (int i = 0; i < n; i++) out[i] = d->freePk[i].load();
    return n;
}
int Session::livePeaks(float* out, int maxBins) const {
    const int n = std::min(maxBins, d->liveN.load());
    for (int i = 0; i < n; i++) out[i] = d->livePk[i].load();
    return n;
}

// ---- library ----
void Session::setDataDir(const std::string& dir) { d->dataDir = dir; }
void Session::setSampleDir(const std::string& dir) { d->sampleDir = dir; }
std::string Session::dataDir() const { return d->dataDir; }
std::string Session::sampleDir() const { return d->sampleDir; }
std::vector<std::string> Session::sampleFolders() const {
    std::vector<std::string> v; std::error_code ec;
    for (auto& e : std::filesystem::directory_iterator(d->sampleDir, ec)) if (e.is_directory()) v.push_back(e.path().filename().string());
    std::sort(v.begin(), v.end()); return v;
}
std::vector<std::string> Session::sampleFiles(const std::string& folder) const {
    std::vector<std::string> v; std::error_code ec;
    for (auto& e : std::filesystem::directory_iterator(d->sampleDir + "/" + folder, ec)) if (e.path().extension() == ".wav") v.push_back(e.path().filename().string());
    std::sort(v.begin(), v.end()); return v;
}
std::vector<std::string> Session::sampleLibrary() const {
    namespace fs = std::filesystem;
    std::vector<std::pair<fs::file_time_type, std::string>> v; std::error_code ec;
    if (d->dataDir.empty()) return {};
    for (auto& e : fs::directory_iterator(d->dataDir, ec)) {
        const auto n = e.path().filename().string();
        if (n.rfind("sample_", 0) == 0 && e.path().extension() == ".wav") v.push_back({e.last_write_time(ec), e.path().string()});
    }
    std::sort(v.begin(), v.end(), [](auto& a, auto& b) { return a.first > b.first; });
    std::vector<std::string> out; for (auto& p : v) out.push_back(p.second);
    return out;
}

// ---- views ----
std::vector<float> Session::samplePeaksOf(int t, int bins) const {
    std::vector<float> out;
    if (t < 0 || t >= kTracks || bins <= 0) return out;
    const auto& tr = *d->tracks[(size_t)t];
    std::lock_guard<std::mutex> l(tr.infoMtx);
    if (tr.peaks.empty()) return out;
    out.assign((size_t)bins, 0.f);
    for (size_t i = 0; i < tr.peaks.size(); i++) { const size_t b = i * (size_t)bins / tr.peaks.size(); out[b] = std::max(out[b], tr.peaks[i]); }
    return out;
}
std::string Session::trackLabel(int t) const {
    if (t < 0 || t >= kTracks) return "";
    std::lock_guard<std::mutex> l(d->tracks[(size_t)t]->infoMtx);
    return d->tracks[(size_t)t]->label;
}
int Session::sampleRate() const { return d->sr; }
Session::Status Session::status() const {
    Status s{};
    s.playing = d->a_playing; s.pos = d->a_pos; s.loopSamples = d->a_loop;
    s.bpm = d->a_bpm; s.loopBars = d->a_bars; s.master_peak = d->a_master; s.cpu_permille = d->a_cpu;
    const uint32_t cm = d->a_clip_mask, rm = d->a_cliprec_mask;
    for (int i = 0; i < kTracks; i++) {
        s.track_peak[i] = d->tracks[(size_t)i]->peak;
        s.track_has_clip[i] = cm >> i & 1; s.track_clip_rec[i] = rm >> i & 1;
        s.clipPos[i] = d->a_clipPos; s.lfoValue[i] = d->a_lfo[i]; s.scGain[i] = d->a_scGain[i]; s.scLevel[i] = d->a_scLevel[i];
        s.samplePlaying[i] = d->a_samplePlaying[i].load();
        s.samplePlaybackPosition[i] = d->a_samplePlaybackPosition[i].load();
        s.voiceN[i] = std::min(kVoiceMax, d->a_voiceN[i].load()); for (int j = 0; j < s.voiceN[i]; j++) { s.voicePos[i][j] = d->a_voicePos[i][j]; s.voiceLvl[i][j] = d->a_voiceLvl[i][j]; }
    }
    s.freeRecording = d->a_free; s.freeArmed = d->a_freeArmed; s.freeSeconds = d->a_freeSec;
    s.sampleState = d->a_sampleState; s.sampleTrack = d->a_sampleTrack; s.sampleSeconds = d->a_sampleSec; s.inputPeak = d->a_inPeak;
    s.sampleVersion = d->a_sampleVersion; s.sampleFails = d->a_sampleFails; s.samplePending = d->a_pending;
    return s;
}
