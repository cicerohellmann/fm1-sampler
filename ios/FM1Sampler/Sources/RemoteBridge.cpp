#include "RemoteBridge.h"
#include "fm1_screen.h"   // engine/tools: the host model of the firmware's draw commands
extern "C" {
#include "rfm/session.h"
}
#include <cstdio>
#include <cstring>

namespace {
// This repository's firmware, the parts the app depends on (firmware/app/ctrl.c).
enum { KEYS = 27, BUTTONS = 14, BTN_OCT_DOWN = 0, BTN_OCT_UP = 1 };
enum { SCALE_OFF = 7, SCALES = 8, MODE_CHORD = 1 };
struct ScaleDef { uint8_t n, step[12]; };
const ScaleDef kScales[SCALES - 1] = {
    {12, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}}, {7, {0, 2, 4, 5, 7, 9, 10}}, {7, {0, 2, 4, 5, 7, 9, 11}},
    {7, {0, 2, 3, 5, 7, 8, 10}}, {7, {0, 2, 3, 5, 7, 8, 11}}, {7, {0, 1, 3, 5, 7, 8, 10}}, {8, {0, 2, 3, 5, 7, 8, 10, 11}},
};
// LED / control id (0..13 buttons, 14..40 keys) -> matrix column (high nibble) and row bit (low nibble): firmware/app/board/fm1_input.h,
// the same matrix as RemoteFM1's FM1_KEYMAP (checked id by id)
const uint8_t kPin[41] = {
    0x04, 0x14, 0x61, 0x41, 0x21, 0x01, 0x92, 0x82, 0x71, 0x51, 0x31, 0x11, 0xa2, 0x72,
    0x34, 0x24, 0x54, 0x44, 0x74, 0x64, 0x84, 0x94, 0xa4, 0x03, 0x13, 0x23, 0x33, 0x43,
    0x53, 0x63, 0x73, 0x83, 0x93, 0xa3, 0x02, 0x12, 0x22, 0x32, 0x42, 0x62, 0x52};
void put7x5(std::vector<uint8_t>& v, uint32_t x) {   // ctrl.c put32: 32 bits as 4+7+7+7+7
    v.push_back((x >> 28) & 15); v.push_back((x >> 21) & 127); v.push_back((x >> 14) & 127); v.push_back((x >> 7) & 127); v.push_back(x & 127);
}
}  // namespace

struct RemoteBridge::Impl {
    Write write;
    Log log;
    mutable std::mutex mtx;
    bool enabled = false;
    rfm_session_t* s = nullptr;
    int link = -1;
    std::string linkName;
    int state = RFM_S_STOPPED;
    bool wasActive = false;
    // the firmware side
    Fm1Screen screen;
    bool screenDirty = true;
    uint64_t ledMask = 0, sentLedMask = ~0ull;
    uint32_t rxFrames = 0, rxBytes = 0, now = 0;
    uint8_t scale = 3, root = 0, mode = 0; int oct = 0;
    uint8_t held[KEYS][3] = {}, heldN[KEYS] = {};
    std::vector<uint8_t> sx; bool inSx = false;   // the app's SysEx stream
    std::vector<uint8_t> toApp;
    uint16_t be[240 * 240];
    std::string status = "REMOTEFM1 OFF";
    uint32_t lastFrameAt = 0;

    std::string lastSaid;
    void say(const std::string& m) { if (log && m != lastSaid) log("remotefm1: " + m); lastSaid = m; }   // discovery repeats itself every second

    // ---- app-bound messages: this repo's firmware as the app knows it ----
    void midi3(uint8_t a, uint8_t b, uint8_t c) { toApp.push_back(a); toApp.push_back(b); toApp.push_back(c); }
    void sysexToApp(std::initializer_list<uint8_t> body) {
        toApp.insert(toApp.end(), {0xf0, 0x7d, 'D', 'A', 'W', 1});
        toApp.insert(toApp.end(), body);
        toApp.push_back(0xf7);
    }
    void reportScale() { sysexToApp({0x41, scale, root, (uint8_t)(oct + 3), mode}); }
    void scaleSet(unsigned sc, unsigned r, int o, unsigned m) {
        scale = (uint8_t)(sc % SCALES); root = (uint8_t)(r % 12); oct = o < -3 ? -3 : o > 3 ? 3 : o; mode = (uint8_t)(m & 1);
        reportScale();
    }
    int degreeNote(unsigned k) const {
        if (scale == SCALE_OFF) return 53 + (int)k;
        const ScaleDef& d = kScales[scale];
        return 60 + root + 12 * oct + (int)(k / d.n) * 12 + d.step[k % d.n];
    }
    void keyDown(unsigned k) {
        if (k >= KEYS || heldN[k]) return;
        const unsigned n = (scale == SCALE_OFF || mode != MODE_CHORD) ? 1 : 3;
        for (unsigned j = 0; j < n; j++) {
            const int note = degreeNote(k + 2 * j);
            if (note < 0 || note > 127) continue;
            midi3(0x90, (uint8_t)note, n > 1 ? 85 : 100);
            held[k][heldN[k]++] = (uint8_t)note;
        }
    }
    void keyUp(unsigned k) {
        if (k >= KEYS) return;
        while (heldN[k]) midi3(0x80, held[k][--heldN[k]], 0);
    }
    void releaseAll() { for (unsigned k = 0; k < KEYS; k++) keyUp(k); }

    void onEvent(const rfm_event_t* e) {
        switch (e->type) {
        case RFM_EV_KEY: if (e->value) keyDown(e->index); else keyUp(e->index); break;
        case RFM_EV_BUTTON:
            if (e->index == BTN_OCT_DOWN || e->index == BTN_OCT_UP) { if (e->value) scaleSet(scale, root, oct + (e->index == BTN_OCT_UP ? 1 : -1), mode); }
            else if (e->index < BUTTONS) midi3(e->value ? 0x91 : 0x81, e->index, e->value ? 100 : 0);
            break;
        case RFM_EV_ENC:
            for (int d = e->value; d;) { const int step = d > 63 ? 63 : d < -63 ? -63 : d; midi3(0xb0, (uint8_t)(16 + e->index), (uint8_t)(64 + step)); d -= step; }
            break;
        case RFM_EV_MASTER: { const unsigned adc = e->value < 0 ? 0 : e->value > 1023 ? 1023 : (unsigned)e->value; midi3(0xb0, 7, (uint8_t)(adc >> 3)); midi3(0xb0, 39, (uint8_t)((adc & 7) << 4)); break; }
        default: break;   // pressure: the app has no use for it
        }
    }

    // ---- app -> FM-1: one command of PROTOCOL.md (top level or inside BATCH) ----
    void command(uint8_t cmd, const uint8_t* p, size_t len) {
        switch (cmd) {
        case 0x0a:   // BATCH
            for (size_t i = 0; i + 3 <= len;) {
                const size_t l = (size_t)(p[i] & 127) << 7 | (p[i + 1] & 127);
                if (l < 1 || i + 2 + l > len) break;
                command(p[i + 2], p + i + 3, l - 1);
                i += 2 + l;
            }
            break;
        case 0x01:   // LED: 6 x 7 bits, little endian
            if (len >= 6) { uint64_t m = 0; for (int i = 0; i < 6; i++) m |= (uint64_t)(p[i] & 127) << (7 * i); ledMask = m & ((1ull << 41) - 1); }
            break;
        case 0x05:   // PING -> PONG id millis rx_frames rx_bytes rx_dropped (nothing is dropped between the app and the bridge)
            if (len >= 2) {
                std::vector<uint8_t> r = {0xf0, 0x7d, 'D', 'A', 'W', 1, 0x40, p[0], p[1]};
                put7x5(r, now); put7x5(r, rxFrames); put7x5(r, rxBytes); put7x5(r, 0);
                r.push_back(0xf7);
                toApp.insert(toApp.end(), r.begin(), r.end());
            }
            break;
        case 0x06: if (len >= 4) scaleSet(p[0], p[1], (int)p[2] - 3, p[3]); break;   // SCALE
        case 0x7e: break;                                                              // NOP
        default: if (screen.cmd(cmd, p, len)) screenDirty = true; break;               // the screen
        }
    }
    void appByte(uint8_t b) {
        if (b == 0xf0) { inSx = true; sx.assign(1, b); return; }
        if (!inSx) return;
        sx.push_back(b);
        if (b == 0xf7) {
            inSx = false;
            if (sx.size() >= 8 && sx[1] == 0x7d && sx[2] == 'D' && sx[3] == 'A' && sx[4] == 'W') {
                rxFrames++; rxBytes += (uint32_t)sx.size();
                command(sx[6], sx.data() + 7, sx.size() - 8);
            }
        } else if (sx.size() > 1100) inSx = false;
    }

    rfm_leds_t ledsOf(uint64_t m) const {
        rfm_leds_t l; memset(&l, 0, sizeof l);
        for (unsigned id = 0; id < 41; id++)
            if (m >> id & 1) l.lit[kPin[id] >> 4] |= (uint8_t)(1u << (kPin[id] & 15));
        return l;
    }

    void newSession() {
        if (s) { rfm_session_free(s); s = nullptr; }
        rfm_session_cfg_t c; rfm_session_cfg_default(&c);
        c.host_name = "FM1 Sampler";
        c.key_touch = 0;   // velocity 100 like this repo's firmware
        rfm_session_cb_t cb; memset(&cb, 0, sizeof cb);
        cb.ctx = this;
        cb.event = [](void* x, const rfm_event_t* e) { static_cast<Impl*>(x)->onEvent(e); };
        cb.state = [](void* x, int st, const char* why) { auto* i = static_cast<Impl*>(x); i->state = st; i->say(std::string(rfm_session_state_name(st)) + (why ? std::string(": ") + why : "")); };
        cb.log = [](void* x, const char* m) { static_cast<Impl*>(x)->say(m); };
        s = rfm_session_new(&c, &cb);
        link = -1;
    }
    void addLink() {
        if (!s || linkName.empty() || link >= 0) return;
        link = rfm_session_add_link(s, RFM_LINK_SX, [](void* x, const uint8_t* p, uint32_t n) { return static_cast<Impl*>(x)->write(p, n); }, this, linkName.c_str());
        say("link " + linkName);
    }
    void updateStatus() {
        if (!enabled) { status = "REMOTEFM1 OFF"; return; }
        const bool act = state == RFM_S_ACTIVE;
        rfm_session_stats_t st; memset(&st, 0, sizeof st); if (s) rfm_session_stats(s, &st);
        char b[96];
        if (act) snprintf(b, sizeof b, "REMOTEFM1 ON %s", st.ble ? "BLUETOOTH" : "USB");
        else if (linkName.empty()) snprintf(b, sizeof b, "REMOTEFM1: NO FM-1 PORT");
        else snprintf(b, sizeof b, "REMOTEFM1: LOOKING (%s)", rfm_session_state_name(state));
        status = b;
    }
};

RemoteBridge::RemoteBridge(Write write, Log log) : d(std::make_unique<Impl>()) {
    d->write = std::move(write); d->log = std::move(log);
    d->screen.fill(0, 0, 240, 240, 0);
}
RemoteBridge::~RemoteBridge() { if (d->s) rfm_session_free(d->s); }

void RemoteBridge::setEnabled(bool on, uint32_t now) {
    std::lock_guard<std::mutex> l(d->mtx);
    if (on == d->enabled) return;
    d->enabled = on; d->now = now;
    if (on) { d->newSession(); d->addLink(); d->state = RFM_S_DISCOVER; }
    else {
        if (d->s) { rfm_session_stop(d->s, now); for (int i = 0; i < 20 && rfm_session_state(d->s) == RFM_S_STOPPING; i++) rfm_session_poll(d->s, now + 20 * i); rfm_session_free(d->s); d->s = nullptr; }
        if (d->wasActive) d->releaseAll();
        d->wasActive = false; d->link = -1; d->state = RFM_S_STOPPED;
    }
    d->updateStatus();
}
bool RemoteBridge::enabled() const { std::lock_guard<std::mutex> l(d->mtx); return d->enabled; }

void RemoteBridge::setLink(const std::string& name, uint32_t now) {
    std::lock_guard<std::mutex> l(d->mtx);
    if (name == d->linkName) return;
    if (d->s && d->link >= 0) { rfm_session_remove_link(d->s, d->link, now); d->link = -1; }
    d->linkName = name;
    d->addLink();
    d->updateStatus();
}
void RemoteBridge::fromUnit(const uint8_t* p, size_t n, uint32_t now) {
    std::lock_guard<std::mutex> l(d->mtx);
    if (d->s && d->link >= 0) rfm_session_rx(d->s, d->link, p, (uint32_t)n, now);
}
void RemoteBridge::fromApp(const uint8_t* p, size_t n) {
    std::lock_guard<std::mutex> l(d->mtx);
    for (size_t i = 0; i < n; i++) d->appByte(p[i]);
}
void RemoteBridge::poll(uint32_t now) {
    std::lock_guard<std::mutex> l(d->mtx);
    d->now = now;
    if (!d->s) return;
    rfm_session_poll(d->s, now);
    d->state = rfm_session_state(d->s);
    const bool act = d->state == RFM_S_ACTIVE;
    if (act && !d->wasActive) {   // a session (again): the unit's screen is black, the app repaints all of it into ours
        d->sysexToApp({0x42});    // REDRAW
        d->reportScale();
        d->sentLedMask = ~0ull; d->screenDirty = true;
    }
    if (!act && d->wasActive) d->releaseAll();   // no stuck notes when the unit goes
    d->wasActive = act;
    if (act) {
        if (d->screenDirty && now - d->lastFrameAt >= 16) {   // the session takes the newest frame and sends what changed, at the link's pace
            for (int i = 0; i < 240 * 240; i++) d->be[i] = __builtin_bswap16(d->screen.px[i]);   // its frames hold the panel's byte order
            rfm_session_set_frame(d->s, d->be);
            d->screenDirty = false; d->lastFrameAt = now;
        }
        if (d->ledMask != d->sentLedMask) { rfm_leds_t ls = d->ledsOf(d->ledMask); rfm_session_set_leds(d->s, &ls); d->sentLedMask = d->ledMask; }
    }
    d->updateStatus();
}
std::vector<uint8_t> RemoteBridge::takeForApp() { std::lock_guard<std::mutex> l(d->mtx); std::vector<uint8_t> r; r.swap(d->toApp); return r; }
bool RemoteBridge::active() const { std::lock_guard<std::mutex> l(d->mtx); return d->enabled && d->state == RFM_S_ACTIVE; }
bool RemoteBridge::bluetooth() const {
    std::lock_guard<std::mutex> l(d->mtx);
    if (!d->s) return false;
    rfm_session_stats_t st; rfm_session_stats(d->s, &st); return st.ble != 0;
}
std::string RemoteBridge::status() const { std::lock_guard<std::mutex> l(d->mtx); return d->status; }
const uint16_t* RemoteBridge::frame() const { return d->screen.px; }
uint64_t RemoteBridge::leds() const { std::lock_guard<std::mutex> l(d->mtx); return d->ledMask; }
