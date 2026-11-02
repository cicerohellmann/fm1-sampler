#include "Core.h"
#include <Session.h>
#include <SamplerApp.h>
#include <SamplerUI.h>

Core::Core(const std::string& dataDir, const std::string& sampleDir) {
    session_ = std::make_unique<Session>(44100);   // the FM-1 runs its USB audio at 44.1 kHz, so the whole engine does too (AudioIO converts if the route differs)
    session_->setDataDir(dataDir); session_->setSampleDir(sampleDir);   // before the app: it reads the library and loads the first samples
    app_ = std::make_unique<SamplerApp>(*session_, [this](const uint8_t* m, size_t n) { out_.insert(out_.end(), m, m + n); });
    ui_ = std::make_unique<SamplerUI>(*app_);
}
Core::~Core() = default;

void Core::midiIn(const uint8_t* d, size_t n) {
    std::lock_guard<std::mutex> l(mtx_);
    for (size_t i = 0; i < n; i++) {
        const uint8_t s = d[i];
        if (s >= 0xf8) continue;                        // real time (clock, active sensing): may come anywhere, even inside a SysEx
        if (inSx_) {                                    // SysEx from the FM-1 (scale state, redraw request), may span calls
            if (s >= 0x80 && s != 0xf7) { inSx_ = false; i--; continue; }   // anything else that starts a message ends a broken SysEx
            if (sx_.size() < 256) sx_.push_back(s);
            if (s == 0xf7) { inSx_ = false; app_->onSysex(sx_.data(), sx_.size()); }
            continue;
        }
        if (s == 0xf0) { inSx_ = true; sx_.assign(1, s); msgLen_ = 0; continue; }
        if (s >= 0xf0) { msgLen_ = 0; continue; }
        if (s >= 0x80) { msg_[0] = s; msgLen_ = 1; msgNeed_ = ((s & 0xf0) == 0xc0 || (s & 0xf0) == 0xd0) ? 2 : 3; continue; }
        if (msgLen_ == 0) continue;                     // a data byte without a status
        msg_[msgLen_++] = s;
        if (msgLen_ == msgNeed_) { if (msgNeed_ == 3) app_->onMidi(msg_, 3); msgLen_ = 1; }   // running status: the status stays
    }
}

std::vector<uint8_t> Core::tick(uint32_t nowMs) {
    std::lock_guard<std::mutex> l(mtx_);
    app_->tick(nowMs);
    std::vector<uint8_t> r; r.swap(out_);
    return r;
}
bool Core::wantFile() { std::lock_guard<std::mutex> l(mtx_); return app_->wantFile(); }
void Core::importFile(const std::string& p) { std::lock_guard<std::mutex> l(mtx_); app_->importFile(p); }
void Core::say(const std::string& m) { std::lock_guard<std::mutex> l(mtx_); app_->say(m); }
void Core::uiLink(bool midi, bool usb) { std::lock_guard<std::mutex> l(mtx_); ui_->setLink(midi, usb); }
void Core::uiFrame(float w, float h, uint32_t now, std::vector<UiOp>& out) {
    std::lock_guard<std::mutex> l(mtx_);
    ui_->setSize(w, h, 0, 0);
    ui_->frame(now);
    out = ui_->ops();
}
void Core::uiTouch(int action, float x, float y, uint32_t now) { std::lock_guard<std::mutex> l(mtx_); ui_->touch(action, x, y, now); }
void Core::playNote(int note, bool down) { std::lock_guard<std::mutex> l(mtx_); app_->playNote(note, down); }
std::string Core::diagLine() {
    std::lock_guard<std::mutex> l(mtx_);
    const Session::Status st = session_->status();
    int voices = 0; for (int t = 0; t < Session::kTracks; t++) voices += st.voiceN[t];
    char b[256];
    snprintf(b, sizeof b, "cpu %.1f%% peak %.3f voices %d playing %d loop %.2fs bars %d bpm %.1f track %d page %s mic %d sample '%s'",
             st.cpu_permille / 10.0, st.master_peak, voices, st.playing, st.loopSamples / 44100.0, st.loopBars, st.bpm, app_->track() + 1,
             SamplerApp::pageName(app_->page()), app_->micState(), app_->sampleLabel(app_->track()).c_str());
    return b;
}
