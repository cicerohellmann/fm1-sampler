// Diagnostics (FM1_FAKE_UNIT=1): this phone plays an FM-1 running RemoteFM1, as a Bluetooth MIDI peripheral, so the sampler on
// another phone can be tested over real Bluetooth without the hardware. RemoteFM1's fake unit (ThirdParty/remotefm1/src/fake.c)
// answers HELLO, SESSION, TILES and LEDS like the firmware (with its Bluetooth HELLO_R: the host paces for Bluetooth) and sends
// the panel's MIDI; its screen and LEDs are shown here.
//   FM1_UNIT_SCRIPT=...  ms after the session started, ';' separated: "<ms> btn <0..13>", "<ms> key <0..26> <hold ms>",
//                        "<ms> enc <0..6> <detents>", "<ms> snap <name>" (this screen as Documents/diag/unit_<name>.png)
#import "FakeUnitViewController.h"
#import "Diag.h"
#import <CoreAudioKit/CoreAudioKit.h>
#import <CoreMIDI/CoreMIDI.h>
extern "C" {
#include "rfm/fake.h"
}
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>
#include <mach/mach_time.h>

namespace {
struct Step { uint32_t at; int kind; int a, b; std::string name; };   // kind 0 btn down, 1 btn up, 2 key down, 3 key up, 4 enc, 5 snap
std::vector<Step> parseUnitScript(NSString* s) {
    std::vector<Step> v;
    for (NSString* item in [s componentsSeparatedByString:@";"]) {
        unsigned at = 0; char what[16] = {0}, name[64] = {0}; int a = 0, b = 0;
        const char* c = item.UTF8String;
        if (sscanf(c, " %u %15s", &at, what) < 2) continue;
        if (!strcmp(what, "snap")) { if (sscanf(c, " %*u %*s %63s", name) == 1) v.push_back({at, 5, 0, 0, name}); continue; }
        if (sscanf(c, " %*u %*s %d %d", &a, &b) < 1) continue;
        if (!strcmp(what, "btn")) { v.push_back({at, 0, a, 0}); v.push_back({at + 100, 1, a, 0}); }
        else if (!strcmp(what, "key")) { v.push_back({at, 2, a, 0}); v.push_back({at + (uint32_t)(b > 0 ? b : 300), 3, a, 0}); }
        else if (!strcmp(what, "enc")) v.push_back({at, 4, a, b});
    }
    std::stable_sort(v.begin(), v.end(), [](const Step& x, const Step& y) { return x.at < y.at; });
    return v;
}
bool endpointIsBluetooth(MIDIEndpointRef e) {
    MIDIEntityRef ent = 0; MIDIDeviceRef dev = 0; CFStringRef s = nullptr; bool ble = false;
    if (MIDIEndpointGetEntity(e, &ent) == noErr && ent && MIDIEntityGetDevice(ent, &dev) == noErr && dev &&
        MIDIObjectGetStringProperty(dev, kMIDIPropertyDriverOwner, &s) == noErr && s) { ble = [((__bridge NSString*)s).lowercaseString containsString:@"bluetooth"]; CFRelease(s); }
    return ble;
}
NSString* nameOf(MIDIEndpointRef e) {
    CFStringRef s = nullptr; NSString* n = @"?";
    if (MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s) == noErr && s) { n = (__bridge_transfer NSString*)s; }
    return n;
}
}  // namespace

@implementation FakeUnitViewController {
    rfm_fake_t* _fake;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    MIDIClientRef _client;
    MIDIPortRef _in, _out;
    std::vector<MIDIEndpointRef> _dsts;
    std::vector<uint8_t> _rx;   // the host's bytes, assembled on _q
    bool _inSx;
    uint64_t _t0; double _toMs;
    UIImageView* _screen;
    UIView* _leds;
    UILabel* _status;
    std::vector<Step> _script; size_t _next; uint32_t _sessionAt; int _lastSession;
    uint8_t _rgba[240 * 240 * 4];
}

- (uint32_t)now { return (uint32_t)((mach_absolute_time() - _t0) * _toMs); }

- (void)viewDidLoad {
    [super viewDidLoad];
    mach_timebase_info_data_t tb; mach_timebase_info(&tb); _toMs = (double)tb.numer / tb.denom / 1e6; _t0 = mach_absolute_time();
    self.view.backgroundColor = UIColor.blackColor;
    _screen = [[UIImageView alloc] init];
    _screen.layer.magnificationFilter = kCAFilterNearest;
    _screen.backgroundColor = UIColor.darkGrayColor;
    [self.view addSubview:_screen];
    _leds = [[UIView alloc] init];
    [self.view addSubview:_leds];
    for (int i = 0; i < 41; i++) { UIView* d = [[UIView alloc] init]; d.tag = 100 + i; d.layer.cornerRadius = 5; d.backgroundColor = UIColor.darkGrayColor; [_leds addSubview:d]; }
    _status = [[UILabel alloc] init];
    _status.numberOfLines = 0; _status.textColor = UIColor.whiteColor; _status.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [self.view addSubview:_status];
    UIButton* adv = [UIButton buttonWithType:UIButtonTypeSystem];
    [adv setTitle:@"Bluetooth MIDI: advertise…" forState:UIControlStateNormal];
    [adv addTarget:self action:@selector(advertise) forControlEvents:UIControlEventTouchUpInside];
    adv.tag = 7;
    [self.view addSubview:adv];

    rfm_fake_cfg_t c; rfm_fake_cfg_default(&c);
    c.ble = 1;   // its HELLO_R says Bluetooth MIDI: the host paces for it, as for a real unit on Bluetooth
    _fake = rfm_fake_new(&c);
    _q = dispatch_queue_create("fm1.fakeunit", DISPATCH_QUEUE_SERIAL);
    _script = parseUnitScript(diagValue(@"FM1_UNIT_SCRIPT") ?: @"");
    _next = 0; _lastSession = 0;
    [self startMidi];
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    __weak FakeUnitViewController* w = self;
    dispatch_source_set_event_handler(_timer, ^{ [w tick]; });
    dispatch_resume(_timer);
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer*) { [w redraw]; }];
    fm1log("fake unit: up");
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    const CGRect b = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    const CGFloat side = std::min(b.size.height - 20, b.size.width * 0.5);
    _screen.frame = CGRectMake(b.origin.x + 10, b.origin.y + 10, side, side);
    const CGFloat x = CGRectGetMaxX(_screen.frame) + 16, w = CGRectGetMaxX(b) - x - 10;
    _leds.frame = CGRectMake(x, b.origin.y + 10, w, 60);
    for (int i = 0; i < 41; i++) {   // buttons in one row, keys in two below
        UIView* d = [_leds viewWithTag:100 + i];
        const int row = i < 14 ? 0 : 1 + (i - 14) / 14, col = i < 14 ? i : (i - 14) % 14;
        d.frame = CGRectMake(col * (w / 14), row * 18, 10, 10);
    }
    [self.view viewWithTag:7].frame = CGRectMake(x, b.origin.y + 76, w, 30);
    _status.frame = CGRectMake(x, b.origin.y + 110, w, b.size.height - 120);
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

// Apple's peripheral panel: switching "Advertise MIDI Service" on makes this phone a Bluetooth MIDI device others can connect to
- (void)advertise {
    CABTMIDILocalPeripheralViewController* p = [[CABTMIDILocalPeripheralViewController alloc] init];
    p.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    UINavigationController* n = [[UINavigationController alloc] initWithRootViewController:p];
    [self presentViewController:n animated:YES completion:nil];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

// ---- MIDI: every Bluetooth source in, every Bluetooth destination out ----
- (void)startMidi {
    __weak FakeUnitViewController* w = self;
    MIDIClientCreateWithBlock(CFSTR("fake FM-1"), &_client, ^(const MIDINotification* m) {
        if (m->messageID == kMIDIMsgSetupChanged) dispatch_async(dispatch_get_main_queue(), ^{ [w connectAll]; });
    });
    MIDIInputPortCreateWithProtocol(_client, CFSTR("in"), kMIDIProtocol_1_0, &_in, ^(const MIDIEventList* list, void*) {
        std::vector<uint8_t> b;
        const MIDIEventPacket* p = &list->packet[0];
        for (UInt32 k = 0; k < list->numPackets; k++, p = MIDIEventPacketNext(p))
            for (UInt32 i = 0; i < p->wordCount;) {
                static const int kWords[16] = {1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4};   // UMP words per message type
                const uint32_t w0 = p->words[i];
                const int words = kWords[w0 >> 28];
                if (i + words > p->wordCount) break;
                if ((w0 >> 28) == 3) {   // SysEx 7 (the host sends only SysEx)
                    const uint32_t w1 = p->words[i + 1];
                    const int st = (w0 >> 20) & 15, cnt = std::min<int>(6, (w0 >> 16) & 15);
                    const uint8_t d[6] = {(uint8_t)((w0 >> 8) & 127), (uint8_t)(w0 & 127), (uint8_t)((w1 >> 24) & 127), (uint8_t)((w1 >> 16) & 127), (uint8_t)((w1 >> 8) & 127), (uint8_t)(w1 & 127)};
                    if (st == 0 || st == 1) b.push_back(0xf0);
                    for (int j = 0; j < cnt; j++) b.push_back(d[j]);
                    if (st == 0 || st == 3) b.push_back(0xf7);
                }
                i += words;
            }
        if (b.empty()) return;
        FakeUnitViewController* s = w;
        if (!s) return;
        dispatch_async(s->_q, ^{ rfm_fake_rx_sx(s->_fake, b.data(), (uint32_t)b.size(), s.now); });
    });
    MIDIOutputPortCreate(_client, CFSTR("out"), &_out);
    [self connectAll];
}
- (void)connectAll {
    logMidiEndpoints("fake unit");
    std::vector<MIDIEndpointRef> dsts;
    NSMutableString* names = [NSMutableString string];
    for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) {
        MIDIEndpointRef e = MIDIGetSource(i);
        if (!endpointIsBluetooth(e)) continue;
        MIDIPortConnectSource(_in, e, nullptr);
        [names appendFormat:@" in:%@", nameOf(e)];
    }
    for (ItemCount i = 0; i < MIDIGetNumberOfDestinations(); i++) {
        MIDIEndpointRef e = MIDIGetDestination(i);
        if (!endpointIsBluetooth(e)) continue;
        dsts.push_back(e);
        [names appendFormat:@" out:%@", nameOf(e)];
    }
    fm1log("fake unit: Bluetooth endpoints%s", names.length ? names.UTF8String : " none");
    dispatch_async(_q, ^{ self->_dsts = dsts; });
}
// the unit's bytes (SysEx replies and the panel's channel messages) -> UMP, MIDI 1.0 protocol
- (void)sendBytes:(const uint8_t*)b length:(size_t)n {
    if (_dsts.empty()) return;
    std::vector<uint8_t> buf(n * 4 + 1024);
    MIDIEventList* list = reinterpret_cast<MIDIEventList*>(buf.data());
    MIDIEventPacket* pkt = MIDIEventListInit(list, kMIDIProtocol_1_0);
    auto add = [&](const uint32_t* w, int words) { MIDIEventPacket* nx = MIDIEventListAdd(list, buf.size(), pkt, 0, words, w); if (nx) pkt = nx; };
    for (size_t i = 0; i < n;) {
        const uint8_t s = b[i];
        if (s == 0xf0) {
            size_t e = i + 1; while (e < n && b[e] != 0xf7) e++;
            const size_t len = e - i - 1;
            for (size_t o = 0; o < len || (len == 0 && o == 0); o += 6) {
                const size_t cnt = std::min<size_t>(6, len - o);
                const uint32_t st = len <= 6 ? 0 : o == 0 ? 1 : o + cnt >= len ? 3 : 2;
                uint8_t x[6] = {0}; for (size_t j = 0; j < cnt; j++) x[j] = b[i + 1 + o + j] & 127;
                const uint32_t w[2] = {0x30000000u | st << 20 | (uint32_t)cnt << 16 | (uint32_t)x[0] << 8 | x[1], (uint32_t)x[2] << 24 | (uint32_t)x[3] << 16 | (uint32_t)x[4] << 8 | x[5]};
                add(w, 2);
                if (len == 0) break;
            }
            i = e + 1;
        } else if (s >= 0x80 && s < 0xf0) {
            const int len = ((s & 0xf0) == 0xc0 || (s & 0xf0) == 0xd0) ? 2 : 3;
            if (i + len > n) break;
            const uint32_t w = 0x20000000u | (uint32_t)s << 16 | (uint32_t)b[i + 1] << 8 | (len == 3 ? b[i + 2] : 0);
            add(&w, 1);
            i += len;
        } else i++;
    }
    for (MIDIEndpointRef d : _dsts) MIDISendEventList(_out, d, list);
}

// ---- the unit (on _q) ----
- (void)tick {
    const uint32_t now = self.now;
    rfm_fake_poll(_fake, now);
    const int sess = rfm_fake_session(_fake);
    if (sess && !_lastSession) { _sessionAt = now; _next = 0; fm1log("fake unit: session started"); }
    if (!sess && _lastSession) fm1log("fake unit: session ended");
    _lastSession = sess;
    while (sess && _next < _script.size() && _script[_next].at <= now - _sessionAt) {
        const Step& s = _script[_next++];
        switch (s.kind) {
        case 0: rfm_fake_button(_fake, s.a, 1); break;
        case 1: rfm_fake_button(_fake, s.a, 0); break;
        case 2: rfm_fake_key(_fake, s.a, 1); break;
        case 3: rfm_fake_key(_fake, s.a, 0); break;
        case 4: rfm_fake_enc(_fake, s.a, s.b); break;
        case 5: { NSString* nm = @(s.name.c_str()); dispatch_async(dispatch_get_main_queue(), ^{ [self snap:nm]; }); break; }
        }
        fm1log("fake unit: step %d %d %d %s", s.kind, s.a, s.b, s.name.c_str());
    }
    uint8_t out[4096]; uint32_t n;
    while ((n = rfm_fake_take_sx(_fake, out, sizeof out)) > 0) [self sendBytes:out length:n];
}

- (void)redraw {
    __block rfm_fake_stats_t st; __block rfm_leds_t leds; __block int sess = 0, holding = 0;
    dispatch_sync(_q, ^{
        const uint8_t* p = rfm_fake_panel(self->_fake);
        for (int i = 0; i < 240 * 240; i++) {
            const uint16_t c = (uint16_t)(p[2 * i] << 8 | p[2 * i + 1]);
            uint8_t* o = &self->_rgba[4 * i]; o[0] = (uint8_t)((c >> 11) << 3); o[1] = (uint8_t)(((c >> 5) & 63) << 2); o[2] = (uint8_t)((c & 31) << 3); o[3] = 255;
        }
        rfm_fake_stats(self->_fake, &st); leds = *rfm_fake_leds(self->_fake); sess = rfm_fake_session(self->_fake); holding = rfm_fake_holding(self->_fake);
    });
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(_rgba, 240, 240, 8, 240 * 4, cs, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    _screen.image = [UIImage imageWithCGImage:img];
    CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    static const uint8_t pin[41] = {0x04, 0x14, 0x61, 0x41, 0x21, 0x01, 0x92, 0x82, 0x71, 0x51, 0x31, 0x11, 0xa2, 0x72, 0x34, 0x24, 0x54, 0x44, 0x74, 0x64, 0x84,
        0x94, 0xa4, 0x03, 0x13, 0x23, 0x33, 0x43, 0x53, 0x63, 0x73, 0x83, 0x93, 0xa3, 0x02, 0x12, 0x22, 0x32, 0x42, 0x62, 0x52};
    for (int i = 0; i < 41; i++) {
        const uint8_t col = pin[i] >> 4, bit = (uint8_t)(1u << (pin[i] & 15));
        UIColor* c = (leds.lit[col] & bit) ? UIColor.orangeColor : (leds.mid[col] | leds.dim[col]) & bit ? [UIColor colorWithWhite:0.5 alpha:1] : UIColor.darkGrayColor;
        [_leds viewWithTag:100 + i].backgroundColor = c;
    }
    _status.text = [NSString stringWithFormat:@"FAKE FM-1 (RemoteFM1, Bluetooth)\nsession %@ %@\nhellos %u  sessions %u/%u\nframes %u  tile bytes %u  held %u\nLEDS %u  PANEL_R %u  decode errors %u\nBluetooth outputs %zu",
        sess ? @"ACTIVE" : @"none", holding ? @"(holding)" : @"", st.hellos, st.sessions_started, st.sessions_ended, st.frames, st.tile_bytes, st.held_frames,
        st.leds, st.panel_r, st.decode_errs, _dsts.size()];
}

- (void)snap:(NSString*)name {
    [self redraw];
    UIGraphicsImageRenderer* r = [[UIGraphicsImageRenderer alloc] initWithBounds:self.view.bounds];
    NSData* png = [r PNGDataWithActions:^(UIGraphicsImageRendererContext*) { [self.view drawViewHierarchyInRect:self.view.bounds afterScreenUpdates:YES]; }];
    NSString* dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"diag"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [png writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"unit_%@.png", name]] atomically:YES];
    fm1log("fake unit: snap %s", name.UTF8String);
}
@end
