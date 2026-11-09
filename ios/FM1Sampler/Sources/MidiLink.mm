#import "MidiLink.h"
#import "Diag.h"
#import <CoreMIDI/CoreMIDI.h>
#include <atomic>
#include <mutex>
#include <vector>

namespace {
NSString* endpointName(MIDIEndpointRef e) {
    CFStringRef s = nullptr;
    NSMutableString* n = [NSMutableString string];
    if (MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s) == noErr && s) { [n appendString:(__bridge NSString*)s]; CFRelease(s); s = nullptr; }
    MIDIEntityRef ent = 0; MIDIDeviceRef dev = 0;
    if (MIDIEndpointGetEntity(e, &ent) == noErr && ent && MIDIEntityGetDevice(ent, &dev) == noErr && dev) {
        if (MIDIObjectGetStringProperty(dev, kMIDIPropertyName, &s) == noErr && s) { [n appendFormat:@" | %@", (__bridge NSString*)s]; CFRelease(s); s = nullptr; }
        if (MIDIObjectGetStringProperty(dev, kMIDIPropertyManufacturer, &s) == noErr && s) { [n appendFormat:@" | %@", (__bridge NSString*)s]; CFRelease(s); }
    }
    return n;
}
// Bluetooth MIDI (Apple's BLE MIDI driver owns the device): slower than USB, never carries audio
bool isBluetooth(MIDIEndpointRef e) {
    MIDIEntityRef ent = 0; MIDIDeviceRef dev = 0; CFStringRef s = nullptr; bool ble = false;
    if (MIDIEndpointGetEntity(e, &ent) == noErr && ent && MIDIEntityGetDevice(ent, &dev) == noErr && dev &&
        MIDIObjectGetStringProperty(dev, kMIDIPropertyDriverOwner, &s) == noErr && s) {
        ble = [((__bridge NSString*)s).lowercaseString containsString:@"bluetooth"]; CFRelease(s);
    }
    return ble;
}
MIDIEntityRef entityOf(MIDIEndpointRef e) { MIDIEntityRef ent = 0; MIDIEndpointGetEntity(e, &ent); return ent; }
bool offline(MIDIEndpointRef e) { SInt32 v = 0; return MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &v) == noErr && v; }
// 2: certainly the FM-1, 1: the loose match of the Android build ("fm" anywhere in the name), 0: not it
NSString* extraMatch() {   // FM1_MIDI_MATCH=<text>: one more name taken as the FM-1 (diagnostics: a network session from the Mac)
    static NSString* m = [diagValue(@"FM1_MIDI_MATCH") lowercaseString];
    return m.length ? m : nil;
}
int score(NSString* name) {
    NSString* n = name.lowercaseString;
    if (extraMatch() && [n containsString:extraMatch()]) return 3;
    if ([n containsString:@"m-vave"] || [n containsString:@"mvave"] || [n containsString:@"fm-1"] || [n containsString:@"fm1"]) return 2;
    return [n containsString:@"fm"] ? 1 : 0;
}
// Words of one UMP message, from its message type.
int umpWords(uint32_t w) { static const int k[16] = {1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4}; return k[w >> 28]; }
}  // namespace

@interface MidiLink ()
@property (atomic, readwrite) BOOL connected;
@property (atomic, readwrite, copy) NSString* deviceName;
@property (atomic, readwrite) BOOL bluetooth;
@end

@implementation MidiLink {
    MidiReceiver _rx;
    MIDIClientRef _client;
    MIDIPortRef _inPort, _outPort;
    MIDIEndpointRef _src;
    std::atomic<MIDIEndpointRef> _dst;
    std::mutex _sendMtx;
    std::vector<uint8_t> _evbuf;
}

- (instancetype)initWithReceiver:(MidiReceiver)rx {
    if ((self = [super init])) { _rx = [rx copy]; _dst = 0; }
    return self;
}

- (void)start {
    __weak MidiLink* weak = self;
#if FM1_TEST_TOOLS
    if (diagValue(@"FM1_NETMIDI")) {   // diagnostics: open the network MIDI session so the Mac can stand in for the FM-1
        MIDINetworkSession* ns = MIDINetworkSession.defaultSession;
        ns.enabled = YES;
        ns.connectionPolicy = MIDINetworkConnectionPolicy_Anyone;
        fm1log("network MIDI session '%s' on port %lu", ns.networkName.UTF8String, (unsigned long)ns.networkPort);
    }
#endif
    OSStatus r = MIDIClientCreateWithBlock(CFSTR("FM1 Sampler"), &_client, ^(const MIDINotification* m) {
        if (m->messageID == kMIDIMsgSetupChanged || m->messageID == kMIDIMsgObjectAdded || m->messageID == kMIDIMsgObjectRemoved || m->messageID == kMIDIMsgPropertyChanged)
            dispatch_async(dispatch_get_main_queue(), ^{ [weak rescan]; });
    });
    if (r != noErr) { fm1log("client: %d", (int)r); return; }
    MidiReceiver rx = _rx;
    // The FM-1 speaks MIDI 1.0; CoreMIDI hands it over as UMP: turn it back into the byte stream the app parses (running status, SysEx).
    r = MIDIInputPortCreateWithProtocol(_client, CFSTR("from FM-1"), kMIDIProtocol_1_0, &_inPort, ^(const MIDIEventList* list, void*) {
        uint8_t b[512]; size_t n = 0;
        auto flush = [&] { if (n) { rx(b, n); n = 0; } };
        auto put = [&](uint8_t v) { if (n == sizeof b) flush(); b[n++] = v; };
        const MIDIEventPacket* p = &list->packet[0];
        for (UInt32 k = 0; k < list->numPackets; k++, p = MIDIEventPacketNext(p)) {
            for (UInt32 i = 0; i < p->wordCount;) {
                const uint32_t w = p->words[i];
                const int words = umpWords(w);
                if (i + words > p->wordCount) break;
                const uint8_t mt = w >> 28;
                if (mt == 0x1) {               // system common / real time
                    const uint8_t s = (w >> 16) & 0xff;
                    put(s);
                    if (s == 0xf1 || s == 0xf3) put((w >> 8) & 0x7f);
                    else if (s == 0xf2) { put((w >> 8) & 0x7f); put(w & 0x7f); }
                } else if (mt == 0x2) {        // MIDI 1.0 channel voice
                    const uint8_t s = (w >> 16) & 0xff;
                    put(s); put((w >> 8) & 0x7f);
                    if ((s & 0xf0) != 0xc0 && (s & 0xf0) != 0xd0) put(w & 0x7f);
                } else if (mt == 0x3) {        // SysEx 7: complete / start / continue / end, up to 6 bytes each
                    const uint32_t w2 = p->words[i + 1];
                    const int st = (w >> 20) & 0xf, cnt = std::min<int>(6, (w >> 16) & 0xf);
                    const uint8_t d[6] = {(uint8_t)((w >> 8) & 0x7f), (uint8_t)(w & 0x7f), (uint8_t)((w2 >> 24) & 0x7f),
                                          (uint8_t)((w2 >> 16) & 0x7f), (uint8_t)((w2 >> 8) & 0x7f), (uint8_t)(w2 & 0x7f)};
                    if (st == 0 || st == 1) put(0xf0);
                    for (int j = 0; j < cnt; j++) put(d[j]);
                    if (st == 0 || st == 3) put(0xf7);
                }
                i += words;
            }
        }
        flush();
    });
    if (r != noErr) fm1log("input port: %d", (int)r);
    r = MIDIOutputPortCreate(_client, CFSTR("to FM-1"), &_outPort);
    if (r != noErr) fm1log("output port: %d", (int)r);
    [self rescan];
}

// The FM-1's source, then the destination of the same device (USB preferred to Bluetooth when both are there: no latency, and
// this repo's firmware answers only over USB).
- (void)rescan {
    logMidiEndpoints("midi");
    MIDIEndpointRef src = 0, dst = 0; int bestS = 0, bestD = 0;
    NSString* srcName = nil;
    for (ItemCount i = 0, n = MIDIGetNumberOfSources(); i < n; i++) {
        MIDIEndpointRef e = MIDIGetSource(i);
        if (!e || offline(e)) continue;
        NSString* nm = endpointName(e); const int s = score(nm) * 2 + (isBluetooth(e) ? 0 : 1);
        if (score(nm) && s > bestS) { bestS = s; src = e; srcName = nm; }
    }
    const MIDIEntityRef srcEntity = src ? entityOf(src) : 0;
    for (ItemCount i = 0, n = MIDIGetNumberOfDestinations(); i < n; i++) {
        MIDIEndpointRef e = MIDIGetDestination(i);
        if (!e || offline(e)) continue;
        const int base = score(endpointName(e));
        if (!base) continue;
        const int s = (srcEntity && entityOf(e) == srcEntity ? 100 : 0) + base * 2 + (isBluetooth(e) ? 0 : 1);
        if (s > bestD) { bestD = s; dst = e; }
    }
    const bool ble = src && isBluetooth(src);
    if (src != _src) {
        if (_src) MIDIPortDisconnectSource(_inPort, _src);
        _src = src;
        if (src) {
            OSStatus r = MIDIPortConnectSource(_inPort, src, nullptr);
            fm1log("FM-1 source: %s%s (%d)", srcName.UTF8String, ble ? " [Bluetooth]" : "", (int)r);
        } else fm1log("FM-1 source gone");
    }
    if (dst != _dst.load()) fm1log("FM-1 destination: %s", dst ? "connected" : "gone");
    _dst = dst;
    self.connected = dst != 0;   // read by the surface thread: through the atomic setters
    self.deviceName = srcName;
    self.bluetooth = ble;
}

- (void)send:(const uint8_t*)b length:(size_t)n {
    const MIDIEndpointRef dst = _dst.load();
    if (!dst || !_outPort || n == 0) return;
    std::lock_guard<std::mutex> l(_sendMtx);
    // SysEx 7 UMP: every 6 data bytes take 2 words. Room for all of it plus the packet headers.
    _evbuf.assign(std::max<size_t>(1024, n * 3 + 256), 0);
    MIDIEventList* list = reinterpret_cast<MIDIEventList*>(_evbuf.data());
    MIDIEventPacket* pkt = MIDIEventListInit(list, kMIDIProtocol_1_0);
    auto add = [&](uint32_t w1, uint32_t w2) {
        const uint32_t w[2] = {w1, w2};
        MIDIEventPacket* next = MIDIEventListAdd(list, _evbuf.size(), pkt, 0, 2, w);
        if (!next) {   // full: send what is there and start a new list
            MIDISendEventList(_outPort, dst, list);
            pkt = MIDIEventListInit(list, kMIDIProtocol_1_0);
            next = MIDIEventListAdd(list, _evbuf.size(), pkt, 0, 2, w);
        }
        pkt = next;
    };
    size_t i = 0;
    while (i < n) {
        if (b[i] != 0xf0) { i++; continue; }   // the app only sends SysEx
        size_t e = i + 1;
        while (e < n && b[e] != 0xf7) e++;
        const uint8_t* d = b + i + 1;
        const size_t len = e - i - 1;
        if (len == 0) {
            add(0x30000000u, 0);
        } else {
            for (size_t o = 0; o < len; o += 6) {
                const size_t cnt = std::min<size_t>(6, len - o);
                const int st = len <= 6 ? 0 : o == 0 ? 1 : o + cnt >= len ? 3 : 2;
                uint8_t x[6] = {0, 0, 0, 0, 0, 0};
                for (size_t j = 0; j < cnt; j++) x[j] = d[o + j] & 0x7f;
                add(0x30000000u | (uint32_t)st << 20 | (uint32_t)cnt << 16 | (uint32_t)x[0] << 8 | x[1],
                    (uint32_t)x[2] << 24 | (uint32_t)x[3] << 16 | (uint32_t)x[4] << 8 | x[5]);
            }
        }
        i = e + 1;
    }
    if (list->numPackets) {
        OSStatus r = MIDISendEventList(_outPort, dst, list);
        if (r != noErr) fm1log("send: %d", (int)r);
    }
}
@end
