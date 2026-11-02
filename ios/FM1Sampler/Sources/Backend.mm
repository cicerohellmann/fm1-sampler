#import "Backend.h"
#import "Diag.h"
#import "AudioIO.h"
#import "MidiLink.h"
#include "Core.h"
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
- (uint32_t)nowMs { return (uint32_t)((mach_absolute_time() - _t0) * _tickToMs); }

- (void)start {
    if (_started) return;
    _started = YES;
    _audio = [[AudioIO alloc] initWithSession:&_core->session()];
    [_audio start];
    Core* core = _core.get();
    _midi = [[MidiLink alloc] initWithReceiver:^(const uint8_t* b, size_t n) { core->midiIn(b, n); }];
    [_midi start];
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
                fm1log("%s | audio %.0f cb/s hw %.0f Hz mic %d usb %d | midi %d %s", core->diagLine().c_str(),
                       (cb - lastCb) * 1000.0 / std::max<uint32_t>(1, now - lastDiag), _audio.hardwareRate, _audio.micRunning, _audio.usbOutput,
                       _midi.connected, (_midi.deviceName ?: @"-").UTF8String);
                lastDiag = now; lastCb = cb;
            }
            std::vector<uint8_t> out = core->tick(self.nowMs);
            if (!out.empty()) [_midi send:out.data() length:out.size()];
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
