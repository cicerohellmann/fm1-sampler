// Host test of the RemoteFM1 bridge: the app (Core: Session + SamplerApp + SamplerUI, as on the phone) drives RemoteFM1's fake unit
// (ThirdParty/remotefm1/src/fake.c) through RemoteBridge, over a USB link and over a Bluetooth one at the measured rate.
//   ./run_tests.sh   (builds this with the engine and libremotefm1 and runs it)
#include "Core.h"
#include "RemoteBridge.h"
#include <Session.h>
extern "C" {
#include "rfm/fake.h"
#include "rfm/session.h"
}
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

static int fails = 0;
#define CHECK(c, ...) do { bool ok_ = (c); printf("%s ", ok_ ? "ok  " : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!ok_) fails++; } while (0)

struct Rig {
    Core core;
    rfm_fake_t* fake;
    RemoteBridge bridge;
    uint32_t t = 0;
    std::vector<float> buf = std::vector<float>(512), in = std::vector<float>(512, 0.f);
    Rig(const char* data, const char* samples, int ble)
        : core(data, samples), fake(nullptr),
          bridge([this](const uint8_t* p, size_t n) { rfm_fake_rx_sx(fake, p, (uint32_t)n, t); return 0; },
                 [](const std::string& m) { if (getenv("VERBOSE")) printf("    %s\n", m.c_str()); }) {
        rfm_fake_cfg_t c; rfm_fake_cfg_default(&c);
        c.ble = ble;
        c.sx_rate_bps = ble ? 6000 : 280000;   // RemoteFM1's measured rates: Bluetooth ~6 KB/s, USB SysEx ~280 KB/s
        fake = rfm_fake_new(&c);
        bridge.setEnabled(true, 0);
        bridge.setLink("FM-1 FAKE", 0);
    }
    ~Rig() { rfm_fake_free(fake); }
    // ms of everything: audio, the app at ~60 Hz, the bridge, the unit
    void run(int ms) {
        for (int i = 0; i < ms; i += 4) {
            t += 4;
            for (int b = 0; b < 1; b++) { std::fill(buf.begin(), buf.end(), 0.f); core.session().process(buf.data(), in.data(), 176); }
            std::this_thread::sleep_for(std::chrono::microseconds(150));   // the worker thread loads samples meanwhile
            if (t % 16 == 0) {
                std::vector<uint8_t> out = core.tick(t);
                if (bridge.active()) bridge.fromApp(out.data(), out.size());
            }
            bridge.poll(t);
            std::vector<uint8_t> a = bridge.takeForApp();
            if (!a.empty()) core.midiIn(a.data(), a.size());
            rfm_fake_poll(fake, t);
            uint8_t rx[4096]; uint32_t n;
            while ((n = rfm_fake_take_sx(fake, rx, sizeof rx)) > 0) bridge.fromUnit(rx, n, t);
        }
    }
    // how many pixels of the unit's panel differ from the app's FM-1 screen
    int diff() const {
        const uint8_t* p = rfm_fake_panel(fake); const uint16_t* f = bridge.frame(); int d = 0;
        for (int i = 0; i < 240 * 240; i++) if ((uint16_t)(p[2 * i] << 8 | p[2 * i + 1]) != f[i]) d++;
        return d;
    }
    int lit() const { const uint16_t* f = bridge.frame(); int n = 0; for (int i = 0; i < 240 * 240; i++) n += f[i] != 0; return n; }
    std::string diag() { return core.diagLine(); }
};

static bool has(const std::string& s, const char* what) { return s.find(what) != std::string::npos; }

static void suite(const char* data, const char* samples, int ble) {
    printf("-- %s link\n", ble ? "Bluetooth" : "USB");
    Rig r(data, samples, ble);
    r.run(2500);
    CHECK(r.bridge.active(), "a session is up (%s)", r.bridge.status().c_str());
    CHECK(r.bridge.bluetooth() == (ble != 0), "the link is %s", ble ? "Bluetooth" : "USB");
    r.run(ble ? 4000 : 1500);   // Bluetooth: the whole screen at ~6 KB/s, then the exact refinement once it is still
    CHECK(r.lit() > 5000, "the app drew its FM-1 screen (%d pixels not black)", r.lit());
    CHECK(r.diff() == 0, "the unit shows exactly the app's FM-1 screen (%d pixels differ)", r.diff());
    {
        const rfm_leds_t* l = rfm_fake_leds(r.fake); int bits = 0;
        for (int c = 0; c < 11; c++) bits += __builtin_popcount(l->lit[c]);
        CHECK(bits > 0 && bits == __builtin_popcountll(r.bridge.leds()), "LEDs: %d lit on the unit, %d in the app's frame", bits, __builtin_popcountll(r.bridge.leds()));
        // HOME (button 8) is lit on the SAMPLE page: column 7, row bit 1 (0x71 in the pin table)
        CHECK(l->lit[7] & 0x02, "the HOME button's LED is lit (column 7 = %02x)", l->lit[7]);
    }
    // a button: FX goes to the FX page
    rfm_fake_button(r.fake, 2, 1); r.run(120); rfm_fake_button(r.fake, 2, 0); r.run(300);
    CHECK(has(r.diag(), "page FX"), "button FX -> page FX (%s)", r.diag().substr(r.diag().find("page")).substr(0, 12).c_str());
    rfm_fake_button(r.fake, 8, 1); r.run(120); rfm_fake_button(r.fake, 8, 0); r.run(300);
    CHECK(has(r.diag(), "page SAMPLE"), "button HOME -> page SAMPLE");
    // a key sounds, its release lets it go
    rfm_fake_key(r.fake, 7, 1); r.run(300);
    const std::string down = r.diag();
    rfm_fake_key(r.fake, 7, 0);
    int gone = -1;
    for (int ms = 0; ms <= 8000 && gone < 0; ms += 250) { r.run(250); if (has(r.diag(), "voices 0 ")) gone = ms + 250; }
    CHECK(!has(down, "voices 0 "), "a key sounds a voice (%s)", down.substr(down.find("voices"), 9).c_str());
    CHECK(gone >= 0, "its release ends it (silent %d ms after the key let go; the default release is 2 s)", gone);
    // the SELECT encoder: track 2, and back
    rfm_fake_enc(r.fake, 0, 1); r.run(300);
    CHECK(has(r.diag(), "track 2 "), "encoder SELECT +1 -> track 2");
    rfm_fake_enc(r.fake, 0, -1); r.run(300);
    CHECK(has(r.diag(), "track 1 "), "encoder SELECT -1 -> track 1");
    // OCT+ is the firmware's (a SCALE report), not a button for the app: the page stays
    rfm_fake_button(r.fake, 1, 1); r.run(120); rfm_fake_button(r.fake, 1, 0); r.run(300);
    CHECK(has(r.diag(), "page SAMPLE"), "OCT+ is not forwarded as a button");
    // after the page changes the unit catches up with the screen again
    rfm_fake_button(r.fake, 4, 1); r.run(120); rfm_fake_button(r.fake, 4, 0); r.run(ble ? 5000 : 1000);
    CHECK(has(r.diag(), "page ENV") && r.diff() == 0, "ENV page shown on the unit exactly (%d pixels differ)", r.diff());
    rfm_session_stats_t st{};
    rfm_fake_stats_t fs{}; rfm_fake_stats(r.fake, &fs);
    CHECK(fs.decode_errs == 0 && fs.frames > 0, "unit: %u frames, %u tile bytes, %u decode errors, %u held", fs.frames, fs.tile_bytes, fs.decode_errs, fs.held_frames);
    // switching the bridge off ends the session on the unit
    r.bridge.setEnabled(false, r.t);
    r.run(200);
    CHECK(!r.bridge.active() && rfm_fake_session(r.fake) == 0, "off: no session (unit %d)", rfm_fake_session(r.fake));
    (void)st;
}

int main(int argc, char** argv) {
    const char* data = "/tmp/fm1sampler_bridge_test";
    std::string samples = std::string(getenv("HOME")) + "/fm1-sampler/samples";
    if (argc > 1) samples = argv[1];
    std::system((std::string("rm -rf ") + data + " && mkdir -p " + data).c_str());
    suite(data, samples.c_str(), 0);
    suite(data, samples.c_str(), 1);
    printf(fails ? "%d FAILED\n" : "ALL OK\n", fails);
    return fails ? 1 : 0;
}
