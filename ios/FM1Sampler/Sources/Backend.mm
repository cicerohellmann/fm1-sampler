#import "Backend.h"
#import "Diag.h"
#import "AudioIO.h"
#import "MidiLink.h"
#include "Core.h"
#include "RemoteBridge.h"
#include <atomic>
#include <memory>
#include <mach/mach_time.h>
#include <unistd.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// Diagnostics, off unless asked for (launch environment or Documents/diag.env, see Diag.h):
//   FM1_DIAG=1          one line of engine / audio / MIDI state in the log every 2 s
//   FM1_SCRIPT=...      timed actions, ';' separated: "<ms> tap <x> <y>" (UI units), "<ms> drag <x1> <y1> <x2> <y2> <dur ms>",
//                       "<ms> note <n> <hold ms>", "<ms> snap <name>" (the screen as Documents/diag/<name>.png)
namespace {
struct Action { uint32_t at; int kind; float a, b; std::string name = {}; };   // kind 0 touch down, 1 touch up, 2 note on, 3 note off, 4 snap, 5 touch move
std::vector<Action> parseScript(const char* s) {
    std::vector<Action> v;
    if (!s) return v;
    std::string all(s); size_t p = 0;
    while (p < all.size()) {
        size_t e = all.find(';', p); if (e == std::string::npos) e = all.size();
        const std::string item = all.substr(p, e - p); p = e + 1;
        unsigned at = 0; char what[16] = {0}, name[64] = {0}; float a = 0, b = 0, c = 0, d = 0, dur = 300;
        if (sscanf(item.c_str(), " %u %15s", &at, what) < 2) continue;
        if (!strcmp(what, "snap")) { if (sscanf(item.c_str(), " %*u %*s %63s", name) == 1) v.push_back({at, 4, 0, 0, name}); continue; }
        if (!strcmp(what, "drag")) {
            if (sscanf(item.c_str(), " %*u %*s %f %f %f %f %f", &a, &b, &c, &d, &dur) < 4) continue;
            v.push_back({at, 0, a, b});
            for (int k = 1; k <= 12; k++) v.push_back({at + (uint32_t)(dur * k / 12), 5, a + (c - a) * k / 12, b + (d - b) * k / 12});
            v.push_back({at + (uint32_t)dur + 20, 1, c, d});
            continue;
        }
        if (sscanf(item.c_str(), " %*u %*s %f %f", &a, &b) < 1) continue;
        if (!strcmp(what, "tap")) { v.push_back({at, 0, a, b}); v.push_back({at + 60, 1, a, b}); }
        else if (!strcmp(what, "note")) { v.push_back({at, 2, a, 0}); v.push_back({at + (uint32_t)(b > 0 ? b : 300), 3, a, 0}); }
    }
    std::stable_sort(v.begin(), v.end(), [](const Action& x, const Action& y) { return x.at < y.at; });
    return v;
}
}  // namespace

@implementation Backend {
    std::unique_ptr<Core> _core;
    AudioIO* _audio;
    MidiLink* _midi;
    NSThread* _ticker;
    uint64_t _t0;
    double _tickToMs;
    BOOL _started;
    // RemoteFM1 (optional, Documents/remotefm1 = "1"): an FM-1 with the RemoteFM1 firmware as the panel, over USB or Bluetooth
    std::unique_ptr<RemoteBridge> _bridge;
    std::atomic<bool> _toggleRemote, _wantBluetooth;
}

+ (instancetype)shared {
    static Backend* b; static dispatch_once_t once;
    dispatch_once(&once, ^{ b = [[Backend alloc] init]; });
    return b;
}

- (instancetype)init {
    if ((self = [super init])) {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        _tickToMs = (double)tb.numer / tb.denom / 1e6;
        _t0 = mach_absolute_time();
        _dataDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        [NSFileManager.defaultManager createDirectoryAtPath:_dataDir withIntermediateDirectories:YES attributes:nil error:nil];
        // the bundled library is read in place (read only): samples/<group>/*.wav in the app bundle
        NSString* samples = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"samples"];
        _core = std::make_unique<Core>(_dataDir.UTF8String, samples.UTF8String);
    }
    return self;
}

- (Core*)core { return _core.get(); }

// the RemoteFM1 switch survives restarts (Documents/remotefm1); FM1_REMOTEFM1=1 switches it on for a test
- (BOOL)remoteFM1Enabled {
    if (diagValue(@"FM1_REMOTEFM1")) return YES;
    NSString* v = [NSString stringWithContentsOfFile:[_dataDir stringByAppendingPathComponent:@"remotefm1"] encoding:NSUTF8StringEncoding error:nil];
    return [v hasPrefix:@"1"];
}
- (void)setRemoteFM1Enabled:(BOOL)on {
    [(on ? @"1" : @"0") writeToFile:[_dataDir stringByAppendingPathComponent:@"remotefm1"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
- (uint32_t)nowMs { return (uint32_t)((mach_absolute_time() - _t0) * _tickToMs); }

- (void)start {
    if (_started) return;
    _started = YES;
    _audio = [[AudioIO alloc] initWithSession:&_core->session()];
    [_audio start];
    Core* core = _core.get();
    __weak Backend* weakSelf = self;
    _bridge = std::make_unique<RemoteBridge>(
        [weakSelf](const uint8_t* p, size_t n) { Backend* s = weakSelf; if (!s) return 1; [s->_midi send:p length:n]; return s->_midi.connected ? 0 : 1; },
        [](const std::string& m) { fm1log("%s", m.c_str()); });
    RemoteBridge* bridge = _bridge.get();
    // The FM-1's bytes: to the bridge while RemoteFM1 is on (it answers HELLO and owns the panel then), else to the app as before
    _midi = [[MidiLink alloc] initWithReceiver:^(const uint8_t* b, size_t n) {
        Backend* s = weakSelf;
        if (bridge->enabled()) bridge->fromUnit(b, n, s ? s.nowMs : 0);
        if (!bridge->active()) core->midiIn(b, n);
    }];
    [_midi start];
    _toggleRemote = false; _wantBluetooth = false;
    if (self.remoteFM1Enabled) bridge->setEnabled(true, self.nowMs);
    core->setExtraRows([bridge, weakSelf]() {   // runs inside the UI's lock: read state, raise flags, nothing else
        std::vector<SamplerUIExtraRow> rows;
        const bool on = bridge->enabled();
        SamplerUIExtraRow a;
        a.label = on ? bridge->status() : "REMOTEFM1 FIRMWARE: OFF";
        a.hint = on ? "tap: off (this repo's firmware over USB again, lowest latency)" : "tap: drive an FM-1 running RemoteFM1, over USB or Bluetooth";
        a.hot = on && bridge->active();
        a.tap = [weakSelf] { Backend* s = weakSelf; if (s) s->_toggleRemote = true; };
        rows.push_back(a);
        SamplerUIExtraRow b;
        b.label = "CONNECT BLUETOOTH FM-1";
        b.hint = on ? "pair an FM-1 running RemoteFM1 (the sound stays on the phone)" : "needs REMOTEFM1 on";
        b.enabled = on;
        b.tap = [weakSelf] { Backend* s = weakSelf; if (s) s->_wantBluetooth = true; };
        rows.push_back(b);
        return rows;
    });
    _ticker = [[NSThread alloc] initWithTarget:self selector:@selector(surfaceLoop) object:nil];
    _ticker.name = @"fm1-surface";
    _ticker.qualityOfService = NSQualityOfServiceUserInteractive;
    [_ticker start];
}

// ~60 Hz like the Android ticker: the app paces its SysEx to the FM-1 itself.
- (void)surfaceLoop {
    Core* core = _core.get();
    const bool diag = diagValue(@"FM1_DIAG") != nil;
    std::vector<Action> script = parseScript(diagValue(@"FM1_SCRIPT").UTF8String);
    size_t next = 0;
    uint32_t lastDiag = 0; uint64_t lastCb = 0;
    bool micWaiting = false;
    while (true) {
        @autoreleasepool {
            const uint32_t now = self.nowMs;
            for (; next < script.size() && script[next].at <= now; next++) {
                const Action& a = script[next];
                if (a.kind == 0) core->uiTouch(0, a.a, a.b, now); else if (a.kind == 1) core->uiTouch(2, a.a, a.b, now);
                else if (a.kind == 5) core->uiTouch(1, a.a, a.b, now);
                else if (a.kind == 4) { NSString* nm = @(a.name.c_str()); dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:@"FM1Snap" object:nm]; }); }
                else core->playNote((int)a.a, a.kind == 2);
                if (a.kind != 5) fm1log("script: %d %.0f %.0f %s", a.kind, a.a, a.b, a.name.c_str());
            }
            if (diag && now - lastDiag >= 2000) {
                const uint64_t cb = _audio.callbacks;
                fm1log("%s | audio %.0f cb/s hw %.0f Hz mic %d usb %d | midi %d%s %s | %s", core->diagLine().c_str(),
                       (cb - lastCb) * 1000.0 / std::max<uint32_t>(1, now - lastDiag), _audio.hardwareRate, _audio.micRunning, _audio.usbOutput,
                       _midi.connected, _midi.bluetooth ? " ble" : "", (_midi.deviceName ?: @"-").UTF8String, _bridge->status().c_str());
                fm1log("mic: %s", _audio.inputStats.UTF8String);
                lastDiag = now; lastCb = cb;
            }
            // a microphone take (phone UI or the FM-1: MIC SAMPLE, or the loop with LOOP SOURCE = MIC) starting while access is denied
            const bool mw = core->micTakeWaiting();
            if (mw && !micWaiting && _audio.micDenied) {
                core->cancelMicTake();
                fm1log("microphone take started while access is denied: asking the user");
                void (^r)(void) = self.onMicDenied;
                if (r) dispatch_async(dispatch_get_main_queue(), r);
            }
            micWaiting = mw;
            if (_toggleRemote.exchange(false)) {
                const bool on = !_bridge->enabled();
                self.remoteFM1Enabled = on;
                _bridge->setEnabled(on, now);
                core->say(on ? "REMOTEFM1 ON" : "REMOTEFM1 OFF");
            }
            if (_wantBluetooth.exchange(false)) {
                void (^r)(void) = self.onBluetoothRequest;
                if (r) dispatch_async(dispatch_get_main_queue(), r);
            }
            // the FM-1 port as the bridge's link (it follows plug / unplug and Bluetooth connections)
            _bridge->setLink(_midi.connected ? std::string((_midi.deviceName ?: @"FM-1").UTF8String) : std::string(), now);
            std::vector<uint8_t> out = core->tick(self.nowMs);
            if (_bridge->active()) _bridge->fromApp(out.data(), out.size());   // RemoteFM1: the bridge is the app's FM-1
            else if (!out.empty()) [_midi send:out.data() length:out.size()];
            _bridge->poll(self.nowMs);
            std::vector<uint8_t> in = _bridge->takeForApp();
            if (!in.empty()) core->midiIn(in.data(), in.size());
            core->uiLink(_midi.connected, _audio.usbOutput);
            if (core->wantFile()) {
                void (^r)(void) = self.onFileRequest;
                if (r) dispatch_async(dispatch_get_main_queue(), r);
            }
        }
        usleep(16000);
    }
}
@end
