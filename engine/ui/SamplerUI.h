// SamplerUI: the phone interface of the sampler + looper as draw ops with its own touch handling, laid out for a 400-unit high landscape screen.
// It shows and edits exactly what the FM-1 shows (SamplerApp::knobs), so both always agree.
#pragma once
#include "../app/SamplerApp.h"
#include "Theme.h"
#include "UiOp.h"
#include <functional>
#include <string>
#include <vector>

class SamplerUI {
public:
    explicit SamplerUI(SamplerApp& app);
    void setSize(float w, float h, float topInset, float bottomInset) { W_ = w; H_ = h; top_ = topInset; bottom_ = bottomInset; }
    void setLink(bool midi, bool usbAudio) { linkMidi_ = midi; linkAudio_ = usbAudio; }
    void frame(uint32_t nowMs);
    void openProject(bool on) { projectOpen_ = on; }
    void setEditor(bool on) { editor_ = on; }   // false: the cassette deck, true: sample / page editor
    struct ExtraRow { std::string label, hint; bool enabled = true, hot = false; std::function<void()> tap; };
    void setExtraRows(std::function<std::vector<ExtraRow>()> rows) { extraRows_ = std::move(rows); }
    const std::vector<UiOp>& ops() const { return ops_; }
    void touch(int action /*0 down 1 move 2 up*/, float x, float y, uint32_t nowMs);

private:
    struct Rect { float x, y, w, h; bool has(float px, float py) const { return px >= x && px < x + w && py >= y && py < y + h; } };
    struct Hit { Rect r; std::function<void(float, float)> down, move; std::function<void()> up; };
    void rrect(Rect r, float rad, uint32_t c);
    void stroke(Rect r, float rad, uint32_t c, float w = 1);
    void text(float x, float cy, float size, uint32_t c, const std::string& s, int align = 0, bool bold = false);
    void line(float x1, float y1, float x2, float y2, uint32_t c, float w = 1);
    void circle(float cx, float cy, float r, uint32_t c);
    void tri(float x1, float y1, float x2, float y2, float x3, float y3, uint32_t c);
    void clip(Rect r);
    void endClip();
    void hit(Rect r, std::function<void(float, float)> down, std::function<void(float, float)> move = nullptr, std::function<void()> up = nullptr);
    void tap(Rect r, std::function<void()> f);
    std::string fit(const std::string& s, float width, float size) const;
    void button(Rect r, const std::string& label, bool on, std::function<void()> f, float size = 11, bool accent = false);

    void topBar(Rect r);
    void deck(Rect r);
    void deckPortrait(Rect r);
    void testKeyboard(Rect r);
    void icon(int kind, float cx, float cy, uint32_t c);
    void setLight(bool on);
    void cassette(Rect r);
    void sampleView(Rect r);
    void pageView(Rect r);   // the schematic of the active page in the place of the sample
    void knob(float cx, float cy, SamplerApp::Page page, int idx, bool unused = false, float hitWidth = 92);
    void timeline(Rect r);
    void key(Rect r, const std::string& label, int icon, bool on, std::function<void()> f, bool hot);
    float loopPos() const;
    void reel(float cx, float cy, float r, float ang);
    void trackList(Rect r);
    void sampleArea(Rect r);
    void pagePanel(Rect r);
    void librarySheet();
    void projectSheet();

    SamplerApp& app_;
    float W_ = 860, H_ = 400, top_ = 0, bottom_ = 0;
    std::vector<UiOp> ops_;
    std::vector<Hit> hits_;
    Hit active_{};
    bool haveActive_ = false;
    uint32_t now_ = 0;
    Session::Status st_{};
    bool linkMidi_ = false, linkAudio_ = false, sheetOpen_ = false, editor_ = false, projectOpen_ = false;
    float sheetScroll_ = 0, sheetLastY_ = 0, sheetMoved_ = 0;
    Rect sheetList_{0, 0, 0, 0};
    uint32_t clearArmed_ = 0;
    std::function<std::vector<ExtraRow>()> extraRows_;
    float dragY_ = 0, dragV_ = 0;
    static constexpr int kHist = 118;   // the mixer picture: the last four seconds of the active channel (its level, the sidechain source, the gain it is pulled down to)
    float hOwn_[kHist] = {}, hSrc_[kHist] = {}, hGain_[kHist] = {}; int hPos_ = 0, hTrack_ = -1; uint32_t hAt_ = 0;
};
