#include "Sampler.h"
#include "Slicer.h"
#include "Wav.h"
#include <cstring>

Sampler::Sampler(int engineRate) : sr_(engineRate) {
    for (int i = 0; i < kVoices; i++) paul_.emplace_back(new PaulStream);
}
Sampler::~Sampler() = default;

bool Sampler::load(const std::string& path) {
    auto buf = std::make_shared<SampleBuf>();
    if (!readWav(path, buf->d, buf->sr)) return false;
    buf->frames = (int)(buf->d.size() / 2);
    if (buf->frames < 64) return false;
    // loudness normalisation: the RMS of the part that sounds (20 ms blocks within 30 dB of the loudest one) goes to a common level
    float pk = 0.f; for (float v : buf->d) pk = std::max(pk, std::fabs(v));
    if (pk > 1e-4f) {
        const int blk = std::max(64, buf->sr / 50); const int nb = std::max(1, buf->frames / blk);
        std::vector<double> e((size_t)nb, 0.0); double emax = 0;
        for (int b = 0; b < nb; b++) { double s = 0; for (int i = b * blk; i < (b + 1) * blk && i < buf->frames; i++) s += (double)buf->d[2 * (size_t)i] * buf->d[2 * (size_t)i] + (double)buf->d[2 * (size_t)i + 1] * buf->d[2 * (size_t)i + 1]; e[(size_t)b] = s / (2.0 * blk); emax = std::max(emax, e[(size_t)b]); }
        double sum = 0; int cnt = 0; for (double v : e) if (v > emax * 1e-3) { sum += v; cnt++; }
        const float rms = cnt ? (float)std::sqrt(sum / cnt) : pk;
        // sparse, peaky material (drums) would stay quiet if only the peak were normalised: it gets the same RMS as sustained sounds, up to +10 dB of peak,
        // and a soft limiter (smooth knee at 0.6, ceiling 0.98) keeps what rises above that
        const float g = std::min(std::min(3.0f / pk, 0.25f / std::max(rms, 1e-4f)), 16.f);
        for (float& v : buf->d) {
            float x = v * g; const float ax = std::fabs(x);
            if (ax > 0.6f) x = (x < 0 ? -1.f : 1.f) * (0.6f + 0.38f * std::tanh((ax - 0.6f) / 0.38f));
            v = x;
        }
    }
    peaks_.assign(512, 0.f);
    for (int b = 0; b < 512; b++) {
        const long a = (long)buf->frames * b / 512, e = std::max(a + 1, (long)buf->frames * (b + 1) / 512), step = std::max(1L, (e - a) / 64);
        float m = 0.f; for (long i = a; i < e; i += step) m = std::max(m, std::fabs(buf->d[(size_t)i * 2]));
        peaks_[(size_t)b] = m;
    }
    onsets_ = findOnsets(buf->d, buf->frames, buf->sr);
    const size_t slash = path.find_last_of("/\\"), dot = path.rfind('.');
    label_ = path.substr(slash == std::string::npos ? 0 : slash + 1);
    if (dot != std::string::npos && dot > (slash == std::string::npos ? 0 : slash)) label_ = label_.substr(0, label_.rfind('.'));
    orig_ = buf;
    reslice();
    return true;
}

void Sampler::reslice() {
    if (!orig_) return;
    const int from = (int)(rangeA_ * orig_->frames), to = std::max(from + 64, (int)(rangeB_ * orig_->frames));
    slices_ = pickSlices(onsets_, from, std::min(to, orig_->frames), orig_->sr, sliceThr_, 16);
    sliceEnd_ = std::min(to, orig_->frames);
}
std::vector<float> Sampler::sliceFractions() const {
    std::vector<float> f;
    if (!orig_ || orig_->frames <= 0) return f;
    for (int s : slices_) f.push_back((float)s / orig_->frames);
    f.push_back((float)(sliceEnd_ / orig_->frames));
    return f;
}
void Sampler::setMode(int m) { m = std::min(kModes - 1, std::max(0, m)); if (m != mode_) { allOff(); mode_ = m; } }
void Sampler::setEnv(float a, float d, float s, float r) { atk_ = a; dec_ = d; sus_ = s; rel_ = r; }
void Sampler::setRange(float a, float b) { rangeA_ = clampf(a, 0.f, 1.f); rangeB_ = clampf(b, 0.f, 1.f); if (rangeB_ < rangeA_ + 0.005f) rangeB_ = std::min(1.f, rangeA_ + 0.005f); reslice(); }
void Sampler::setProcessed(std::shared_ptr<const SampleBuf> p, float a, float b) { allOff(); proc_ = std::move(p); procA_ = a; procB_ = std::max(a + 0.001f, b); }

void Sampler::resolveWindow(Voice& v, const SampleBuf*& buf, double& ws, double& we) const {
    if (mode_ == KIT || !proc_) {
        buf = orig_.get();
        if (mode_ == KIT) {
            const int n = (int)slices_.size(), i = v.slice % n;
            ws = slices_[(size_t)i]; we = i + 1 < n ? slices_[(size_t)i + 1] : sliceEnd_;
        } else { ws = rangeA_ * buf->frames; we = rangeB_ * buf->frames; }
    } else {
        buf = proc_.get();   // a stretched copy of [procA, procB]: the window is the same range inside it
        const double span = procB_ - procA_;
        ws = clampf((float)((rangeA_ - procA_) / span), 0.f, 1.f) * buf->frames; we = clampf((float)((rangeB_ - procA_) / span), 0.f, 1.f) * buf->frames;
    }
    we = std::min<double>(we, buf->frames - 2); ws = std::min(ws, we - 16);
    if (ws < 0) ws = 0;
}

void Sampler::noteOn(int note, int vel) {
    if (!orig_) return;
    int vi = -1; uint32_t oldest = 0xffffffffu;
    if (mode_ == PAUL) {   // each voice costs FFTs: at most four at once
        int active = 0; for (auto& v : voices_) active += v.on;
        if (active >= 4) { for (int i = 0; i < kVoices; i++) if (voices_[i].on && voices_[i].born < oldest) { oldest = voices_[i].born; vi = i; } }
    }
    if (vi < 0) for (int i = 0; i < kVoices; i++) if (!voices_[i].on) { vi = i; break; }
    if (vi < 0) { oldest = 0xffffffffu; for (int i = 0; i < kVoices; i++) if (voices_[i].born < oldest) { oldest = voices_[i].born; vi = i; } }
    Voice& v = voices_[vi];
    v = Voice();
    v.on = true; v.gate = true; v.note = note; v.vel = clampf(vel / 127.f, 0.f, 1.f); v.born = ++bornCounter_;
    v.slice = ((note - 60) % 16 + 16) % 16;
    resolveWindow(v, v.buf, v.ws, v.we);
    v.pos = v.ws;
    v.env.set(atk_, dec_, sus_, rel_, (float)sr_);
    if (mode_ == ONESHOT) v.env.set(0.002f, 0.01f, 1.f, 0.01f, (float)sr_);
    v.env.gateOn();
    if (mode_ == PAUL) { v.paulIdx = vi; paul_[(size_t)vi]->start(v.buf->d.data(), v.buf->frames, v.ws, v.we, paulStretch_); }
}
void Sampler::noteOff(int note) {
    if (mode_ == ONESHOT) return;   // always plays out
    for (auto& v : voices_) if (v.on && v.born != transportVoice_ && v.gate && v.note == note) { v.gate = false; v.env.gateOff(); }
}
void Sampler::allOff() {
    for (auto& v : voices_) v = Voice();
    transportVoice_ = 0;
    transportPaused_ = false;
}
bool Sampler::transportPlaybackActive() const {
    if (transportPaused_) return false;
    for (const auto& voice : voices_) {
        if (voice.on && voice.born == transportVoice_) return true;
    }
    return false;
}

void Sampler::clearTransportPlayback() {
    for (auto& v : voices_) if (v.on && v.born == transportVoice_) v = Voice();
    transportVoice_ = 0;
    transportPaused_ = false;
}
void Sampler::seekTransportPlayback(float position) {
    if (!orig_) return;
    auto voice = std::find_if(std::begin(voices_), std::end(voices_), [this](const Voice& v) {
        return v.on && v.born == transportVoice_;
    });
    if (voice == std::end(voices_)) {
        setTransportPlayback(true);
        transportPaused_ = true;
        voice = std::find_if(std::begin(voices_), std::end(voices_), [this](const Voice& v) {
            return v.on && v.born == transportVoice_;
        });
        if (voice == std::end(voices_)) return;
    }
    Voice& v = *voice;
    double fraction = clampf(position, 0.f, 1.f);
    if (v.buf == proc_.get()) fraction = (fraction - procA_) / (procB_ - procA_);
    v.pos = std::clamp(fraction * v.buf->frames, v.ws, std::max(v.ws, v.we - 1));
    if (mode_ == GRAIN) {
        for (auto& grain : v.grain) grain.on = false;
        v.spawn = 0;
    }
    if (mode_ == PAUL && v.paulIdx >= 0) {
        paul_[(size_t)v.paulIdx]->start(v.buf->d.data(), v.buf->frames, v.pos, v.we, paulStretch_);
    }
}

void Sampler::setTransportPlayback(bool play) {
    for (auto& v : voices_) {
        if (v.on && v.born == transportVoice_) {
            transportPaused_ = !play;
            return;
        }
    }
    if (!play || !orig_) return;
    noteOn(60, 100);
    transportVoice_ = bornCounter_;
    transportPaused_ = false;
}
bool Sampler::hasVoices() const { for (auto& v : voices_) if (v.on) return true; return false; }

void Sampler::render(float* out, int n) {
    if (!orig_) return;
    for (auto& v : voices_) if (v.on && !(transportPaused_ && v.born == transportVoice_)) renderVoice(v, out, n);
}

void Sampler::renderVoice(Voice& v, float* out, int n) {
    const float* d = v.buf->d.data(); const int frames = v.buf->frames;
    const double srcRate = (double)v.buf->sr / sr_;
    const double pitch = mode_ == KIT ? std::pow(2.0, (kitSemis_ + bend_) / 12.0) : std::pow(2.0, (v.note - root_ + bend_) / 12.0);
    const double rate = srcRate * pitch;
    auto readAt = [&](double p, float& l, float& r) {
        const int i0 = std::min(frames - 2, std::max(0, (int)p)); const float f = (float)(p - i0);
        l = d[(size_t)i0 * 2] + (d[(size_t)i0 * 2 + 2] - d[(size_t)i0 * 2]) * f;
        r = d[(size_t)i0 * 2 + 1] + (d[(size_t)i0 * 2 + 3] - d[(size_t)i0 * 2 + 1]) * f;
    };
    const float gain = 0.8f * v.vel;
    for (int i = 0; i < n; i++) {
        float l = 0.f, r = 0.f;
        const float e = v.env.next();
        if (v.env.done() && !v.gate) { v.on = false; return; }
        if (mode_ == PAUL) {
            PaulStream& ps = *paul_[(size_t)v.paulIdx];
            ps.next(pitch, l, r);
            if (paulWidth_ != 1.f) { const float m = 0.5f * (l + r), sd = 0.5f * (l - r) * paulWidth_; l = m + sd; r = m - sd; }
            v.pos = ps.sourcePos();
        } else if (mode_ == GRAIN) {
            v.spawn -= 1.0;
            v.pos += (v.we - v.ws) / (4.0 * sr_); if (v.pos >= v.we) v.pos = v.ws;
            if (v.spawn <= 0.0) {
                for (auto& g : v.grain) if (!g.on) {
                    g.on = true; g.age = 0; g.len = (int)(sr_ * grainLen_ * (0.5f + rnd()));
                    const float k = rnd(); const double mult = k < 0.15 ? 0.5 : k < 0.3 ? 2.0 : 1.0;
                    g.inc = rate * mult * (1.0 + (rnd() - 0.5) * 0.004) * (rnd() < 0.2f ? -1.0 : 1.0);
                    // the cursor sweeps the window in about four seconds; scatter is how far around it a grain may start (1 = anywhere in the window)
                    const double win = std::max(1.0, v.we - v.ws), room = std::max(1.0, win - g.len * std::fabs(g.inc));
                    double p = v.pos + (rnd() - 0.5) * grainScatter_ * win;
                    p = std::min(v.we - g.len * std::fabs(g.inc) - 1, std::max(v.ws, p));
                    g.pos = g.inc > 0 ? p : std::min(v.we - 1, p + g.len * std::fabs(g.inc));
                    (void)room;
                    break;
                }
                v.spawn = sr_ * (double)grainLen_ / grainN_ * (0.6 + 0.8 * rnd());
            }
            for (auto& g : v.grain) {
                if (!g.on) continue;
                if (g.age >= g.len || g.pos < 1 || g.pos >= frames - 2) { g.on = false; continue; }
                const float w = 0.5f - 0.5f * std::cos(2.f * kPi * (g.age + 0.5f) / g.len);
                float gl, gr; readAt(g.pos, gl, gr); l += gl * w; r += gr * w;
                g.pos += g.inc; g.age++;
            }
            l *= 0.5f; r *= 0.5f;
        } else {
            double p = v.pos;
            if (mode_ == LOOPED) {
                const double xf = std::min(256.0, (v.we - v.ws) * 0.25);
                readAt(p, l, r);
                if (p >= v.we - xf) { const double t = (p - (v.we - xf)) / xf; float l2, r2; readAt(v.ws + (p - (v.we - xf)), l2, r2); l = l * (float)(1 - t) + l2 * (float)t; r = r * (float)(1 - t) + r2 * (float)t; }
                v.pos += rate;
                if (v.pos >= v.we) v.pos = v.ws + xf + (v.pos - v.we);
            } else {
                if (p >= v.we) { v.on = false; return; }
                readAt(p, l, r);
                const float tail = (float)std::min(1.0, (v.we - p) / (128.0 * rate));   // short fade at the end of the window
                l *= tail; r *= tail;
                v.pos += rate;
            }
        }
        out[2 * i] += l * e * gain; out[2 * i + 1] += r * e * gain;
    }
}

float Sampler::orginalPosOf(const Voice& v) const {
    if (!orig_) return 0.f;
    double pos = v.pos;
    if (v.buf == proc_.get() && proc_) pos = (procA_ + pos / std::max(1, v.buf->frames) * (procB_ - procA_)) * orig_->frames;
    else if (v.buf && v.buf->frames != orig_->frames) pos = pos / v.buf->frames * orig_->frames;
    return clampf((float)(pos / orig_->frames), 0.f, 1.f);
}

float Sampler::transportPlaybackPosition() const {
    for (const auto& voice : voices_) {
        if (voice.on && voice.born == transportVoice_) return orginalPosOf(voice);
    }
    return -1.f;
}

int Sampler::voicePositions(float* out, int maxN, float* level) const {
    int n = 0;
    for (auto& v : voices_) {
        if (!v.on || v.born == transportVoice_ || n >= maxN) continue;
        if (mode_ == GRAIN) {
            for (auto& g : v.grain) if (g.on && n < maxN) {
                Voice tmp = v; tmp.pos = g.pos; if (level) level[n] = v.env.level * std::sin(3.14159265f * std::min(1.f, (float)g.age / (float)std::max(1, g.len))); out[n++] = orginalPosOf(tmp);
            }
        } else { if (level) level[n] = v.env.level * v.vel; out[n++] = orginalPosOf(v); }
    }
    return n;
}
