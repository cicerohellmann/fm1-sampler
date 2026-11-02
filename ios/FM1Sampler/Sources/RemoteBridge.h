// RemoteBridge: lets the sampler drive an FM-1 that runs the RemoteFM1 firmware (github.com/Quixotic7/RemoteFM1) instead of
// this repository's firmware, over USB-MIDI or Bluetooth MIDI. Optional: off unless switched on, and even then the native
// path (this repo's firmware over USB) stays as it is until a unit answers RemoteFM1's HELLO.
//
// The app (SamplerApp) keeps talking PROTOCOL.md to "its FM-1"; the bridge plays that firmware's side of it on the phone:
//   app -> FM-1   draw commands are decoded into a 240x240 frame (engine/tools/fm1_screen.h, the firmware's decoder), LEDs
//                 into RemoteFM1's LED columns, PING answered with PONG, SCALE kept (the key mapping below)
//   FM-1 -> app   RemoteFM1's panel events (keys 9F 53+k, buttons 9E b, encoders BE 16+e, MASTER BE 07/27) become this
//                 firmware's messages: keys through the scale on channel 1, buttons on channel 2 (OCT-/OCT+ handled here and
//                 reported as SCALE, like app/ctrl.c), encoders CC 16+e on channel 1, MASTER CC 7 / 39
// libremotefm1 (ThirdParty/remotefm1, MPL-2.0) does the session, discovery, LEDS and the screen as changed tiles, paced
// for the link (Bluetooth: about 6 KB/s, whole screen changes with HOLD).
//
// Pure C++ (no platform calls) so the host test can run it against RemoteFM1's fake unit. Thread-safe: every call takes
// the bridge's lock; it never calls back into the app (app-bound bytes queue for takeForApp).
#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

class RemoteBridge {
public:
    using Write = std::function<int(const uint8_t*, size_t)>;   // bytes to the unit's MIDI port; 0 ok
    using Log = std::function<void(const std::string&)>;
    RemoteBridge(Write write, Log log = nullptr);
    ~RemoteBridge();

    void setEnabled(bool on, uint32_t nowMs);          // off: the session ends (SESSION 0), the link goes
    bool enabled() const;
    void setLink(const std::string& name, uint32_t nowMs);   // the FM-1 port changed ("" = none)
    void fromUnit(const uint8_t* p, size_t n, uint32_t nowMs);   // every byte the FM-1's port delivered
    void fromApp(const uint8_t* p, size_t n);          // SysEx the app sends to its FM-1 (only while active())
    void poll(uint32_t nowMs);                         // ~60 Hz
    std::vector<uint8_t> takeForApp();                 // MIDI for the app, as if from this repo's firmware

    bool active() const;                               // a RemoteFM1 session runs: the bridge is the app's FM-1
    bool bluetooth() const;                            // ... over Bluetooth MIDI
    std::string status() const;                        // one line for the UI

    // for the tests
    const uint16_t* frame() const;                     // the decoded FM-1 screen, native RGB565
    uint64_t leds() const;                             // the app's LED mask (bit 0..13 buttons, 14..40 keys)

private:
    struct Impl;
    std::unique_ptr<Impl> d;
};
