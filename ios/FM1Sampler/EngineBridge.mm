#import "EngineBridge.h"
#import "AudioImport.h"
#import "AudioIO.h"
#import <AVFAudio/AVFAudio.h>
#import <UIKit/UIKit.h>
#import <CoreMIDI/CoreMIDI.h>
#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <vector>
#include <Session.h>
#include <SamplerApp.h>
#include <SamplerUI.h>

namespace {
struct EngineState {
    Session session{44100};
    std::unique_ptr<SamplerApp> app;
    std::unique_ptr<SamplerUI> ui;
    std::mutex mutex;
    __strong AudioIO *audio;
    MIDIClientRef midiClient = 0;
    MIDIPortRef midiInput = 0, midiOutput = 0;
    std::vector<MIDIEndpointRef> sources, destinations;
    std::atomic<bool> midiSetupChanged{false};
    std::vector<uint8_t> midiOut, sysex;
    bool inSysex = false, midiLinked = false;
    uint8_t message[3] = {0, 0, 0};
    int messageLength = 0, messageNeed = 3;

    EngineState() {
        NSArray<NSURL *> *dirs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        if (dirs.count) session.setDataDir(dirs.firstObject.path.UTF8String);
        NSBundle *bundle = [NSBundle mainBundle];
        NSURL *resourceRoot = bundle.resourceURL;
        NSMutableArray<NSURL *> *sampleCandidates = [NSMutableArray array];
        NSURL *namedSamples = [bundle URLForResource:@"samples" withExtension:nil];
        if (namedSamples) [sampleCandidates addObject:namedSamples];
        if (resourceRoot) {
            [sampleCandidates addObject:[resourceRoot URLByAppendingPathComponent:@"samples" isDirectory:YES]];
            [sampleCandidates addObject:[resourceRoot URLByAppendingPathComponent:@"assets/samples" isDirectory:YES]];
            [sampleCandidates addObject:resourceRoot]; // Xcode may flatten a folder resource into the resource root.
        }
        for (NSURL *candidate in sampleCandidates) {
            BOOL isDirectory = NO;
            NSString *keys = [candidate.path stringByAppendingPathComponent:@"Keys"];
            NSString *drums = [candidate.path stringByAppendingPathComponent:@"Drums"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:keys isDirectory:&isDirectory] && isDirectory &&
                [[NSFileManager defaultManager] fileExistsAtPath:drums]) {
                session.setSampleDir(candidate.path.UTF8String);
                break;
            }
        }
        app = std::make_unique<SamplerApp>(session, [this](const uint8_t *bytes, size_t count) {
            midiOut.insert(midiOut.end(), bytes, bytes + count);
        });
        ui = std::make_unique<SamplerUI>(*app);
        startMIDI();
        audio = [[AudioIO alloc] initWithSession:&session];
        [audio start];
    }

    ~EngineState() {
        [audio stop];
        stopMIDI();
    }

    static void midiRead(const MIDIPacketList *list, void *refCon, void *) {
        auto *self = static_cast<EngineState *>(refCon);
        if (!self || !list) return;
        std::lock_guard<std::mutex> lock(self->mutex);
        const MIDIPacket *packet = &list->packet[0];
        for (UInt32 p = 0; p < list->numPackets; ++p) {
            for (UInt16 i = 0; i < packet->length; ++i) self->consumeMIDI(packet->data[i]);
            packet = MIDIPacketNext(packet);
        }
    }

    void consumeMIDI(uint8_t byte) {
        if (byte >= 0xf8) return;
        if (inSysex) {
            if (byte >= 0x80 && byte != 0xf7) { inSysex = false; sysex.clear(); consumeMIDI(byte); return; }
            if (sysex.size() < 256) sysex.push_back(byte);
            if (byte == 0xf7) { inSysex = false; app->onSysex(sysex.data(), sysex.size()); sysex.clear(); }
            return;
        }
        if (byte == 0xf0) { inSysex = true; sysex.assign(1, byte); messageLength = 0; return; }
        if (byte >= 0xf0) { messageLength = 0; return; }
        if (byte >= 0x80) {
            message[0] = byte; messageLength = 1;
            messageNeed = ((byte & 0xf0) == 0xc0 || (byte & 0xf0) == 0xd0) ? 2 : 3;
            return;
        }
        if (!messageLength) return;
        message[messageLength++] = byte;
        if (messageLength == messageNeed) {
            if (messageNeed == 3) app->onMidi(message, 3);
            messageLength = 1; // running status remains in message[0]
        }
    }

    static void midiNotify(const MIDINotification *notification, void *refCon) {
        if (notification->messageID == kMIDIMsgSetupChanged ||
            notification->messageID == kMIDIMsgObjectAdded ||
            notification->messageID == kMIDIMsgObjectRemoved ||
            notification->messageID == kMIDIMsgPropertyChanged) {
            static_cast<EngineState *>(refCon)->midiSetupChanged.store(true);
        }
    }

    static bool isFM1(MIDIEndpointRef endpoint) {
        SInt32 offline = 0;
        if (endpoint && MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline) == noErr && offline) {
            return false;
        }
        CFStringRef name = nullptr;
        if (!endpoint || MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) != noErr || !name) return false;
        NSString *displayName = CFBridgingRelease(name);
        return [displayName rangeOfString:@"FM-1" options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [displayName rangeOfString:@"FM1" options:NSCaseInsensitiveSearch].location != NSNotFound;
    }

    void startMIDI() {
        if (MIDIClientCreate(CFSTR("FM1Sampler"), midiNotify, this, &midiClient) != noErr) return;
        if (MIDIInputPortCreate(midiClient, CFSTR("FM1Sampler Input"), midiRead, this, &midiInput) != noErr) return;
        if (MIDIOutputPortCreate(midiClient, CFSTR("FM1Sampler Output"), &midiOutput) != noErr) return;
        midiSetupChanged.store(true);
    }

    void refreshMIDI() {
        if (!midiInput || !midiOutput || !midiSetupChanged.exchange(false)) return;
        std::vector<MIDIEndpointRef> newSources, newDestinations;
        for (ItemCount i = 0; i < MIDIGetNumberOfSources(); ++i) {
            MIDIEndpointRef endpoint = MIDIGetSource(i);
            if (isFM1(endpoint)) newSources.push_back(endpoint);
        }
        for (ItemCount i = 0; i < MIDIGetNumberOfDestinations(); ++i) {
            MIDIEndpointRef endpoint = MIDIGetDestination(i);
            if (isFM1(endpoint)) newDestinations.push_back(endpoint);
        }
        if (sources == newSources && destinations == newDestinations) return;

        for (MIDIEndpointRef endpoint : sources) MIDIPortDisconnectSource(midiInput, endpoint);
        sources.clear();
        {
            std::lock_guard<std::mutex> lock(mutex);
            inSysex = false;
            sysex.clear();
            messageLength = 0;
            midiOut.clear();
            destinations = std::move(newDestinations);
            app->resetSurfaceLink();
        }
        for (MIDIEndpointRef endpoint : newSources) {
            if (MIDIPortConnectSource(midiInput, endpoint, nullptr) == noErr) sources.push_back(endpoint);
        }
        midiLinked = !sources.empty() && !destinations.empty();
        NSLog(@"[FM1MIDI] linked=%d inputs=%zu outputs=%zu", midiLinked, sources.size(), destinations.size());
    }

    void sendMIDI() {
        if (midiLinked && !midiOut.empty()) {
            size_t start = 0;
            for (size_t end = 0; end < midiOut.size(); ++end) {
                if (midiOut[end] != 0xf7) continue;
                alignas(8) uint8_t storage[512];
                auto *packets = reinterpret_cast<MIDIPacketList *>(storage);
                MIDIPacket *packet = MIDIPacketListInit(packets);
                if (MIDIPacketListAdd(packets, sizeof(storage), packet, 0, end - start + 1, midiOut.data() + start)) {
                    for (MIDIEndpointRef endpoint : destinations) MIDISend(midiOutput, endpoint, packets);
                }
                start = end + 1;
            }
        }
        midiOut.clear();
    }

    void stopMIDI() {
        if (midiInput) { MIDIPortDispose(midiInput); midiInput = 0; }
        if (midiOutput) { MIDIPortDispose(midiOutput); midiOutput = 0; }
        if (midiClient) { MIDIClientDispose(midiClient); midiClient = 0; }
    }


};
}

@implementation EngineBridge {
    std::unique_ptr<EngineState> _engine;
}

- (instancetype)init {
    self = [super init];
    if (self) _engine = std::make_unique<EngineState>();
    return self;
}

- (void)tick:(uint32_t)now {
    if (!_engine) return;
    _engine->refreshMIDI();
    std::lock_guard<std::mutex> lock(_engine->mutex);
    _engine->app->tick(now);
    if (_engine->audio.micDenied && _engine->app->micState() == 1) {
        _engine->app->micSample();
        _engine->app->say("ALLOW MICROPHONE IN IOS SETTINGS");
    }
    _engine->sendMIDI();
}

- (NSDictionary<NSString *, id> *)frameWithWidth:(float)width height:(float)height top:(float)top bottom:(float)bottom now:(uint32_t)now {
    if (!_engine) return @{@"ops": @[], @"texts": @[]};
    std::lock_guard<std::mutex> lock(_engine->mutex);
    _engine->ui->setLink(_engine->midiLinked, _engine->audio.usbOutput);
    _engine->ui->setSize(width, height, top, bottom);
    _engine->ui->frame(now);
    NSMutableArray *ops = [NSMutableArray array];
    NSMutableArray *texts = [NSMutableArray array];
    for (const auto &op : _engine->ui->ops()) {
        NSMutableArray *row = [NSMutableArray arrayWithCapacity:9];
        [row addObject:@((int)op.type)];
        for (int i = 0; i < 6; ++i) [row addObject:@(op.f[i])];
        [row addObject:@(op.color)];
        int textIndex = -1;
        if (op.type == UiOp::TEXT) { textIndex = (int)texts.count; [texts addObject:[NSString stringWithUTF8String:op.text.c_str()] ?: @""]; }
        [row addObject:@(textIndex)]; [ops addObject:row];
    }
    return @{@"ops": ops, @"texts": texts};
}

- (void)touch:(int)action x:(float)x y:(float)y now:(uint32_t)now {
    if (!_engine) return;
    std::lock_guard<std::mutex> lock(_engine->mutex);
    _engine->ui->touch(action, x, y, now);
}

- (BOOL)takeFileRequest {
    if (!_engine) return NO;
    std::lock_guard<std::mutex> lock(_engine->mutex);
    return _engine->app->wantFile();
}

+ (NSDictionary<NSString *, NSString *> *)prepareSampleFromURL:(NSURL *)url {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *documents = [files URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *staging = [files.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *error = nil;
    if (![files createDirectoryAtURL:staging withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"[FM1Import] staging failed: %@", error);
        return @{@"error": [@"无法创建导入目录：" stringByAppendingString:error.localizedDescription]};
    }

    NSURL *localFile = [staging URLByAppendingPathComponent:url.lastPathComponent];
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSError *copyError = nil;
    __block BOOL copied = NO;
    [coordinator coordinateReadingItemAtURL:url options:0 error:&error byAccessor:^(NSURL *readableURL) {
        NSError *accessError = nil;
        copied = [files copyItemAtURL:readableURL toURL:localFile error:&accessError];
        copyError = accessError;
    }];
    if (scoped) [url stopAccessingSecurityScopedResource];

    NSString *path = copied ? [AudioImport importURL:localFile toDir:documents.path error:&error] : nil;
    if (!path) NSLog(@"[FM1Import] import failed: %@", copyError ?: error);
    [files removeItemAtURL:staging error:nil];
    if (path) return @{@"path": path};

    NSError *failure = copyError ?: error;
    NSString *stage = !copied ? @"无法读取文件" :
        [failure.domain isEqualToString:NSPOSIXErrorDomain] ? @"无法保存采样" : @"无法解码音频";
    NSString *detail = failure ? [NSString stringWithFormat:@"%@ (%@ %ld)", failure.localizedDescription,
                                   failure.domain, (long)failure.code] : @"没有可读的音频数据";
    return @{@"error": [NSString stringWithFormat:@"%@：%@", stage, detail]};
}

- (void)loadImportedSample:(NSString *)path {
    if (!_engine) return;
    std::lock_guard<std::mutex> lock(_engine->mutex);
    _engine->app->importFile(path.UTF8String);
}

- (void)refreshConnections { if (_engine) _engine->midiSetupChanged.store(true); }

- (void)stop { _engine.reset(); }

@end
