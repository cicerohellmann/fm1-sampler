// fm1emu: a stand-in for the M-VAVE FM-1 on the Mac, for testing the iOS app on a real iPhone without the hardware.
// It joins the app's network MIDI session over AppleMIDI / RTP-MIDI (RFC 6295, the protocol of iOS's MIDINetworkSession; the app is launched with
// FM1_NETMIDI=1 FM1_MIDI_MATCH=session), plays the FM-1 side of PROTOCOL.md (keys, panel buttons, encoders, SCALE every 2 s, PONG for every PING)
// and draws the screen commands it receives into a 240x240 frame (engine/tools/fm1_screen.h, the host model of the firmware's decoder),
// saved as PNG on `snap`. It speaks the protocol itself because macOS 26 no longer hands MIDINetworkSession to command line tools.
//
//   clang++ -std=c++20 -fobjc-arc -I../../engine/tools fm1emu.mm -framework Foundation -framework CoreGraphics -framework ImageIO -o fm1emu
//   ./fm1emu --address <iPhone ip> [--port 5004] --out <dir> --script "wait 3000; snap home; btn 4; enc 2 5; snap env; key 60 400"
//
// Script: wait <ms> | redraw | btn <index> | hold <index> <ms> | enc <0..6> <delta> | key <note> <ms> | chord <n1,n2,..> <ms> | snap <name> | leds | stats
//         | expect <what> <min>  (fails the run when a counter is below min: frames, pings, notes)
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "fm1_screen.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

static Fm1Screen gScreen;
static std::mutex gMtx, gSendMtx;
static std::vector<uint8_t> gSx;
static bool gInSx = false;
static uint64_t gLeds = 0;
static std::atomic<uint32_t> gRxFrames{0}, gRxBytes{0}, gPings{0}, gScreenCmds{0}, gRxPackets{0};
static std::atomic<bool> gConnected{false};
static std::atomic<uint32_t> gDropped{0};   // RTP packets lost on the way (sequence gaps): reported as rx_dropped, so the app resends like after an FM-1 queue overflow
static int gLastSeq = -1;
static int gFails = 0;
static const auto gT0 = std::chrono::steady_clock::now();
static uint64_t nowUs() { return (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - gT0).count(); }
static void msleep(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

// ---- AppleMIDI session (initiator) ----
static int gCtl = -1, gData = -1;
static sockaddr_in gPeerCtl{}, gPeerData{};
static const uint32_t kSsrc = 0x464d3145;   // "FM1E"
static const uint32_t kToken = 0x12345678;
static uint16_t gSeq = 1;

static void be16(std::vector<uint8_t>& v, uint16_t x) { v.push_back(x >> 8); v.push_back(x & 255); }
static void be32(std::vector<uint8_t>& v, uint32_t x) { for (int i = 3; i >= 0; i--) v.push_back((x >> (8 * i)) & 255); }
static void be64(std::vector<uint8_t>& v, uint64_t x) { for (int i = 7; i >= 0; i--) v.push_back((x >> (8 * i)) & 255); }
static uint32_t rd32(const uint8_t* p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint64_t rd64(const uint8_t* p) { return (uint64_t)rd32(p) << 32 | rd32(p + 4); }
static void sendTo(int s, const sockaddr_in& a, const std::vector<uint8_t>& b) { sendto(s, b.data(), b.size(), 0, (const sockaddr*)&a, sizeof a); }
static std::vector<uint8_t> invitation(const char* cmd) {
    std::vector<uint8_t> v = {0xff, 0xff, (uint8_t)cmd[0], (uint8_t)cmd[1]};
    be32(v, 2); be32(v, kToken); be32(v, kSsrc);
    if (cmd[0] == 'I') { const char* n = "FM-1 emulator"; v.insert(v.end(), n, n + strlen(n) + 1); }
    return v;
}
static void clockSync(uint8_t count, uint64_t t1, uint64_t t2, uint64_t t3) {
    std::vector<uint8_t> v = {0xff, 0xff, 'C', 'K'};
    be32(v, kSsrc); v.push_back(count); v.push_back(0); v.push_back(0); v.push_back(0);
    be64(v, t1); be64(v, t2); be64(v, t3);
    sendTo(gData, gPeerData, v);
}
static uint64_t ts100us() { return nowUs() / 100; }

// MIDI bytes -> one RTP-MIDI packet (the whole message list, no delta times beyond zero, no journal)
static void sendBytes(const std::vector<uint8_t>& midi) {
    if (!gConnected) return;
    std::lock_guard<std::mutex> l(gSendMtx);
    std::vector<uint8_t> v = {0x80, 0x61};
    be16(v, gSeq++); be32(v, (uint32_t)ts100us()); be32(v, kSsrc);
    // the MIDI list: commands separated by a zero delta time
    std::vector<uint8_t> list;
    for (size_t i = 0; i < midi.size();) {
        if (i) list.push_back(0);   // delta time 0
        const uint8_t s = midi[i];
        size_t n = s == 0xf0 ? (size_t)(std::find(midi.begin() + i, midi.end(), 0xf7) - midi.begin()) - i + 1 : ((s & 0xf0) == 0xc0 || (s & 0xf0) == 0xd0) ? 2 : 3;
        n = std::min(n, midi.size() - i);
        list.insert(list.end(), midi.begin() + i, midi.begin() + i + n);
        i += n;
    }
    if (list.size() <= 15) v.push_back((uint8_t)list.size());
    else { v.push_back(0x80 | (uint8_t)((list.size() >> 8) & 0x0f)); v.push_back(list.size() & 0xff); }
    v.insert(v.end(), list.begin(), list.end());
    sendTo(gData, gPeerData, v);
}
static void put7(std::vector<uint8_t>& v, uint32_t x, int n) { for (int i = n - 1; i >= 0; i--) v.push_back((x >> (7 * i)) & 127); }

// ---- the FM-1 side ----
// One command of PROTOCOL.md (top level or inside a BATCH). Returns the PONG to send, if any. Called under gMtx.
static void command(uint8_t cmd, const uint8_t* p, size_t len, std::vector<uint8_t>& reply) {
    if (cmd == 0x0a) {   // BATCH: { length n14, cmd, payload }...
        for (size_t i = 0; i + 3 <= len;) {
            const size_t l = (size_t)(p[i] & 127) << 7 | (p[i + 1] & 127);
            if (l < 1 || i + 2 + l > len) break;
            command(p[i + 2], p + i + 3, l - 1, reply);
            i += 2 + l;
        }
    } else if (cmd == 0x05 && len >= 2) {   // PING id -> PONG id millis rx_frames rx_bytes rx_dropped
        gPings++;
        reply = {0xf0, 0x7d, 'D', 'A', 'W', 1, 0x40, p[0], p[1]};
        put7(reply, (uint32_t)(nowUs() / 1000), 5); put7(reply, gRxFrames, 5); put7(reply, gRxBytes, 5); put7(reply, gDropped, 5);
        reply.push_back(0xf7);
    } else if (cmd == 0x01 && len >= 6) {
        uint64_t v = 0; for (int i = 0; i < 6; i++) v |= (uint64_t)(p[i] & 127) << (7 * i);
        gLeds = v;
    } else if (cmd != 0x06 && cmd != 0x7e) {   // 06 SCALE is the firmware's key mapping, 7E NOP: nothing to draw
        gScreen.cmd(cmd, p, len); gScreenCmds++;
    }
}
static void onSysex(const std::vector<uint8_t>& m) {
    if (m.size() < 8 || m[1] != 0x7d || m[2] != 'D' || m[3] != 'A' || m[4] != 'W') return;
    std::vector<uint8_t> reply;
    {
        std::lock_guard<std::mutex> l(gMtx);
        gRxFrames++; gRxBytes += (uint32_t)m.size();
        command(m[6], m.data() + 7, m.size() - 8, reply);
    }
    if (!reply.empty()) sendBytes(reply);
}
static void midiByte(uint8_t b) {
    if (b >= 0xf8) return;
    if (b == 0xf0) { gInSx = true; gSx.assign(1, b); return; }
    if (gInSx) { gSx.push_back(b); if (b == 0xf7) { gInSx = false; onSysex(gSx); } else if (gSx.size() > 400) gInSx = false; }
}
// one RTP-MIDI packet from the phone: walk the command list (delta times, running status, SysEx segments)
static void onRtp(const uint8_t* p, size_t n) {
    if (n < 13) return;
    gRxPackets++;
    const int seq = p[2] << 8 | p[3];
    if (gLastSeq >= 0) { const int gap = (seq - gLastSeq - 1) & 0xffff; if (gap && gap < 1000) { gDropped += gap; gInSx = false; } }
    gLastSeq = seq;
    size_t i = 12;
    const uint8_t h = p[i++];
    size_t len = h & 0x0f;
    if (h & 0x80) { if (i >= n) return; len = (len << 8) | p[i++]; }
    const bool z = h & 0x20;
    const size_t end = std::min(n, i + len);
    uint8_t running = 0; bool first = true;
    while (i < end) {
        if (!first || z) { for (int k = 0; k < 4 && i < end; k++) if (!(p[i++] & 0x80)) break; }   // delta time
        first = false;
        if (i >= end) break;
        uint8_t s = p[i];
        if (s == 0xf0 || s == 0xf7) {   // SysEx or a segment of one: F0..F7 whole, F0..F0 first, F7..F0 middle, F7..F7 last
            const bool cont = s == 0xf7; i++;
            if (!cont) midiByte(0xf0);
            while (i < end && p[i] != 0xf7 && p[i] != 0xf0 && p[i] != 0xf4) midiByte(p[i++]);
            if (i < end) { if (p[i] == 0xf7) midiByte(0xf7); i++; }
            continue;
        }
        if (s >= 0x80) { running = s; i++; } else if (!running) { i++; continue; }
        const int data = ((running & 0xf0) == 0xc0 || (running & 0xf0) == 0xd0) ? 1 : running >= 0xf0 ? 0 : 2;
        i += data;
    }
}

static bool connectSession(const char* address, int port) {
    gCtl = socket(AF_INET, SOCK_DGRAM, 0); gData = socket(AF_INET, SOCK_DGRAM, 0);
    for (int base = 5104; base < 5200; base += 2) {   // our control / data ports must be neighbours
        sockaddr_in a{}; a.sin_family = AF_INET; a.sin_addr.s_addr = INADDR_ANY;
        a.sin_port = htons(base); if (bind(gCtl, (sockaddr*)&a, sizeof a)) continue;
        a.sin_port = htons(base + 1); if (bind(gData, (sockaddr*)&a, sizeof a)) { close(gCtl); gCtl = socket(AF_INET, SOCK_DGRAM, 0); continue; }
        break;
    }
    gPeerCtl.sin_family = AF_INET; inet_pton(AF_INET, address, &gPeerCtl.sin_addr); gPeerCtl.sin_port = htons(port);
    gPeerData = gPeerCtl; gPeerData.sin_port = htons(port + 1);
    timeval tv{0, 500000}; setsockopt(gCtl, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv); setsockopt(gData, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    auto handshake = [&](int s, const sockaddr_in& peer, const char* what) {
        for (int t = 0; t < 10; t++) {
            sendTo(s, peer, invitation("IN"));
            uint8_t b[256]; ssize_t r = recv(s, b, sizeof b, 0);
            if (r >= 16 && b[0] == 0xff && b[1] == 0xff) {
                if (b[2] == 'O' && b[3] == 'K') { printf("%s port: accepted by '%s'\n", what, r > 16 ? (const char*)b + 16 : "?"); return true; }
                if (b[2] == 'N' && b[3] == 'O') { printf("%s port: invitation refused\n", what); return false; }
            }
        }
        printf("%s port: no answer\n", what); return false;
    };
    if (!handshake(gCtl, gPeerCtl, "control") || !handshake(gData, gPeerData, "data")) return false;
    tv = {0, 0}; setsockopt(gData, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    gConnected = true;
    std::thread([] {   // data port: clock sync answers and the phone's MIDI
        uint8_t b[2048];
        while (true) {
            ssize_t r = recv(gData, b, sizeof b, 0);
            if (r <= 0) continue;
            if (b[0] == 0xff && b[1] == 0xff && r >= 36 && b[2] == 'C' && b[3] == 'K') {
                const uint8_t count = b[8];
                if (count == 0) clockSync(1, rd64(b + 12), ts100us(), 0);            // the phone started a sync
                else if (count == 1) clockSync(2, rd64(b + 12), rd64(b + 20), ts100us());   // the answer to ours
                continue;
            }
            if (b[0] == 0xff && b[1] == 0xff) { if (b[2] == 'B' && b[3] == 'Y') { printf("the phone ended the session\n"); gConnected = false; } continue; }
            if ((b[0] & 0xc0) == 0x80) onRtp(b, (size_t)r);
        }
    }).detach();
    std::thread([] {   // control port: keep reading (the phone may end the session there)
        uint8_t b[256];
        while (true) { ssize_t r = recv(gCtl, b, sizeof b, 0); if (r >= 4 && b[2] == 'B' && b[3] == 'Y') { printf("the phone ended the session\n"); gConnected = false; } }
    }).detach();
    std::thread([] { while (true) { clockSync(0, ts100us(), 0, 0); msleep(gRxPackets < 3 ? 1000 : 10000); } }).detach();
    return true;
}

static void savePng(const std::string& path) {
    const int Z = 2, W = 240 * Z;
    std::vector<uint8_t> rgb(W * W * 4);
    { std::lock_guard<std::mutex> l(gMtx);
      for (int y = 0; y < W; y++) for (int x = 0; x < W; x++) {
          const uint16_t c = gScreen.px[(y / Z) * 240 + x / Z]; uint8_t* o = &rgb[(y * W + x) * 4];
          o[0] = (c >> 11) << 3; o[1] = ((c >> 5) & 63) << 2; o[2] = (c & 31) << 3; o[3] = 255; } }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgb.data(), W, W, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path.c_str())], CFSTR("public.png"), 1, nullptr);
    CGImageDestinationAddImage(d, img, nullptr); CGImageDestinationFinalize(d);
    CFRelease(d); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
}

static void note(int ch, int n, bool on) { sendBytes({(uint8_t)((on ? 0x90 : 0x80) | ch), (uint8_t)n, (uint8_t)(on ? 100 : 0)}); }

int main(int argc, char** argv) {
    @autoreleasepool {
        std::string address, out = ".", script; int port = 5004;
        for (int i = 1; i + 1 < argc; i += 2) {
            std::string k = argv[i];
            if (k == "--address") address = argv[i + 1]; else if (k == "--port") port = atoi(argv[i + 1]);
            else if (k == "--out") out = argv[i + 1]; else if (k == "--script") script = argv[i + 1];
        }
        if (address.empty() || !connectSession(address.c_str(), port)) { printf("no session\n"); return 2; }
        for (int i = 0; i < 100 && gPings == 0; i++) msleep(100);
        sendBytes({0xf0, 0x7d, 'D', 'A', 'W', 1, 0x42, 0xf7});   // REDRAW once the phone talks to us: it repaints the whole (here: empty) screen
        printf("pings from the app: %u\n", gPings.load());
        std::thread([] { while (true) { sendBytes({0xf0, 0x7d, 'D', 'A', 'W', 1, 0x41, 7, 0, 3, 0, 0xf7}); msleep(2000); } }).detach();   // SCALE: OFF (the app keeps it chromatic)
        std::stringstream ss(script); std::string item;
        while (std::getline(ss, item, ';')) {
            std::stringstream is(item); std::string cmd; is >> cmd;
            if (cmd.empty()) continue;
            printf("> %s\n", item.c_str()); fflush(stdout);
            if (cmd == "wait") { int ms; is >> ms; msleep(ms); }
            else if (cmd == "btn") { int b; is >> b; note(1, b, true); msleep(80); note(1, b, false); msleep(150); }
            else if (cmd == "hold") { int b, ms; is >> b >> ms; note(1, b, true); msleep(ms); note(1, b, false); msleep(150); }
            else if (cmd == "enc") { int e, d; is >> e >> d; while (d) { const int s = std::max(-63, std::min(63, d)); sendBytes({0xb0, (uint8_t)(16 + e), (uint8_t)(64 + s)}); d -= s; msleep(30); } msleep(150); }
            else if (cmd == "key") { int n, ms; is >> n >> ms; note(0, n, true); msleep(ms); note(0, n, false); msleep(80); }
            else if (cmd == "chord") { std::string l; int ms; is >> l >> ms; std::vector<int> v; std::stringstream ls(l); std::string t; while (std::getline(ls, t, ',')) v.push_back(std::stoi(t)); for (int n : v) note(0, n, true); msleep(ms); for (int n : v) note(0, n, false); msleep(80); }
            else if (cmd == "snap") { std::string nm; is >> nm; msleep(500); savePng(out + "/fm1_" + nm + ".png"); printf("  saved fm1_%s.png\n", nm.c_str()); }
            else if (cmd == "redraw") sendBytes({0xf0, 0x7d, 'D', 'A', 'W', 1, 0x42, 0xf7});
            else if (cmd == "leds") { std::lock_guard<std::mutex> l(gMtx); printf("  leds buttons %04llx keys %07llx\n", gLeds & 0x3fff, gLeds >> 14); }
            else if (cmd == "stats") printf("  rtp packets %u (lost %u) sysex %u bytes %u pings %u screen commands %u connected %d\n", gRxPackets.load(), gDropped.load(), gRxFrames.load(), gRxBytes.load(), gPings.load(), gScreenCmds.load(), gConnected.load());
            else if (cmd == "expect") {
                std::string what; unsigned min; is >> what >> min;
                const unsigned v = what == "frames" ? gRxFrames.load() : what == "pings" ? gPings.load() : what == "screen" ? gScreenCmds.load() : 0;
                printf("  %s %s: %u (min %u)\n", v >= min ? "ok  " : "FAIL", what.c_str(), v, min); if (v < min) gFails++;
            }
            fflush(stdout);
        }
        sendTo(gCtl, gPeerCtl, invitation("BY"));
        printf("done: rtp packets %u sysex %u pings %u screen commands %u, %d failed expectations\n", gRxPackets.load(), gRxFrames.load(), gPings.load(), gScreenCmds.load(), gFails);
        return gFails ? 1 : 0;
    }
}
