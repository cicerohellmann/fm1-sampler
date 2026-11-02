#import "AudioIO.h"
#import "Diag.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#include <Session.h>
#include <Common.h>
#include <atomic>
#include <vector>

static const double kRate = 44100;
static const UInt32 kMaxFrames = 4096;

namespace {
// Everything the render callback touches: plain data, no Objective-C on the audio thread.
struct RenderCtx {
    Session* session = nullptr;
    AudioUnit unit = nullptr;
    std::atomic<bool> input{false};
    std::atomic<uint64_t> callbacks{0};
    std::vector<float> inMono = std::vector<float>(kMaxFrames), inStereo = std::vector<float>(kMaxFrames * 2);
};

OSStatus render(void* ref, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts, UInt32 bus, UInt32 frames, AudioBufferList* io) {
    Denormals::enableOnThisThread();
    RenderCtx& c = *static_cast<RenderCtx*>(ref);
    float* out = static_cast<float*>(io->mBuffers[0].mData);
    if (frames > kMaxFrames || !out) { for (UInt32 b = 0; b < io->mNumberBuffers; b++) memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize); return noErr; }
    const float* in = nullptr;
    if (c.input.load(std::memory_order_relaxed)) {
        AudioBufferList abl;
        abl.mNumberBuffers = 1;
        abl.mBuffers[0].mNumberChannels = 1;
        abl.mBuffers[0].mDataByteSize = frames * sizeof(float);
        abl.mBuffers[0].mData = c.inMono.data();
        AudioUnitRenderActionFlags f = 0;
        const bool ok = AudioUnitRender(c.unit, &f, ts, 1, frames, &abl) == noErr;
        for (UInt32 i = 0; i < frames; i++) { const float v = ok ? c.inMono[i] : 0.f; c.inStereo[2 * i] = v; c.inStereo[2 * i + 1] = v; }
        in = c.inStereo.data();
    }
    c.session->process(out, in, (int)frames);
    c.callbacks.fetch_add(1, std::memory_order_relaxed);
    return noErr;
}
}  // namespace

@implementation AudioIO {
    RenderCtx _ctx;
    BOOL _running, _wantMic;
    dispatch_queue_t _q;   // every session / unit call runs here: activation can block for a while, never on the main thread
}

- (instancetype)initWithSession:(Session*)session {
    if ((self = [super init])) {
        _ctx.session = session;
        _q = dispatch_queue_create("fm1.audio", DISPATCH_QUEUE_SERIAL);
        NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(interrupted:) name:AVAudioSessionInterruptionNotification object:nil];
        [nc addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
        [nc addObserver:self selector:@selector(servicesReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
        [nc addObserver:self selector:@selector(foreground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}

- (void)start { dispatch_async(_q, ^{ [self startOnQueue]; }); }
- (uint64_t)callbacks { return _ctx.callbacks.load(std::memory_order_relaxed); }

- (void)startOnQueue {
    [self configureSession];
    const AVAudioApplicationRecordPermission p = AVAudioApplication.sharedInstance.recordPermission;
    _wantMic = p == AVAudioApplicationRecordPermissionGranted;
    [self buildUnit];
    if (p == AVAudioApplicationRecordPermissionUndetermined) {
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
            dispatch_async(self->_q, ^{
                fm1log("microphone permission: %d", granted);
                if (granted) { self->_wantMic = YES; [self buildUnit]; }
            });
        }];
    }
}

- (void)configureSession {
    AVAudioSession* s = AVAudioSession.sharedInstance;
    NSError* e = nil;
    // play and record: the microphone samples while the loop plays. Speaker rather than the earpiece; A2DP headphones stay in stereo.
    // Mixable, like the Android build (Oboe takes no audio focus): another app starting its audio does not silence the sampler.
    if (![s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault
                options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                        AVAudioSessionCategoryOptionMixWithOthers error:&e])
        fm1log("category: %s", e.description.UTF8String);
    [s setPreferredSampleRate:kRate error:nil];
    [s setPreferredIOBufferDuration:0.005 error:nil];
    if (![s setActive:YES error:&e]) fm1log("activate: %s", e.description.UTF8String);
    [self preferBuiltInMic];
    [self updateRoute];
}

// The phone's own microphone, never the USB device (same as the Android build).
- (void)preferBuiltInMic {
    AVAudioSession* s = AVAudioSession.sharedInstance;
    if ([s.preferredInput.portType isEqualToString:AVAudioSessionPortBuiltInMic]) return;
    for (AVAudioSessionPortDescription* p in s.availableInputs)
        if ([p.portType isEqualToString:AVAudioSessionPortBuiltInMic]) { [s setPreferredInput:p error:nil]; break; }
}

- (void)updateRoute {
    AVAudioSession* s = AVAudioSession.sharedInstance;
    BOOL usb = NO;
    for (AVAudioSessionPortDescription* p in s.currentRoute.outputs) if ([p.portType isEqualToString:AVAudioSessionPortUSBAudio]) usb = YES;
    _usbOutput = usb;
    _hardwareRate = s.sampleRate;
    NSMutableArray* outs = [NSMutableArray array], *ins = [NSMutableArray array];
    for (AVAudioSessionPortDescription* p in s.currentRoute.outputs) [outs addObject:[NSString stringWithFormat:@"%@ (%@)", p.portName, p.portType]];
    for (AVAudioSessionPortDescription* p in s.currentRoute.inputs) [ins addObject:[NSString stringWithFormat:@"%@ (%@)", p.portName, p.portType]];
    fm1log("route: out %s | in %s | rate %.0f, buffer %.1f ms", [outs componentsJoinedByString:@", "].UTF8String, [ins componentsJoinedByString:@", "].UTF8String,
           s.sampleRate, s.IOBufferDuration * 1000);
}

- (void)teardownUnit {
    if (!_ctx.unit) return;
    AudioOutputUnitStop(_ctx.unit);
    AudioUnitUninitialize(_ctx.unit);
    AudioComponentInstanceDispose(_ctx.unit);
    _ctx.unit = nullptr;
    _ctx.input = false;
    _running = NO;
    _micRunning = NO;
}

// (Re)creates the RemoteIO unit: output always, input when the microphone is allowed. Falls back to output only if the input cannot be set up.
- (void)buildUnit {
    [self teardownUnit];
    for (int attempt = 0; attempt < 2; attempt++) {
        const BOOL withInput = _wantMic && attempt == 0;
        if ([self tryBuild:withInput]) {
            _micRunning = withInput;
            fm1log("audio started (input %d)", withInput);
            return;
        }
        [self teardownUnit];
        if (!_wantMic) break;
    }
    fm1log("audio could not start");
}

- (BOOL)tryBuild:(BOOL)withInput {
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(nullptr, &d);
    if (!comp || AudioComponentInstanceNew(comp, &_ctx.unit) != noErr) return NO;
    AudioUnit u = _ctx.unit;
    UInt32 one = 1, zero = 0;
    OSStatus r = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, sizeof one);
    r |= AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, withInput ? &one : &zero, sizeof one);
    AudioStreamBasicDescription out = {};
    out.mSampleRate = kRate; out.mFormatID = kAudioFormatLinearPCM; out.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    out.mChannelsPerFrame = 2; out.mBitsPerChannel = 32; out.mFramesPerPacket = 1; out.mBytesPerFrame = 8; out.mBytesPerPacket = 8;
    r |= AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &out, sizeof out);
    if (withInput) {
        AudioStreamBasicDescription in = out;
        in.mChannelsPerFrame = 1; in.mBytesPerFrame = 4; in.mBytesPerPacket = 4;
        r |= AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &in, sizeof in);
    }
    UInt32 maxFrames = kMaxFrames;
    AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof maxFrames);
    AURenderCallbackStruct cb = {render, &_ctx};
    r |= AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (r != noErr) { fm1log("unit setup failed (input %d): %d", withInput, (int)r); return NO; }
    _ctx.input = withInput;
    if ((r = AudioUnitInitialize(u)) != noErr) { fm1log("initialize failed (input %d): %d", withInput, (int)r); return NO; }
    if ((r = AudioOutputUnitStart(u)) != noErr) { fm1log("start failed (input %d): %d", withInput, (int)r); return NO; }
    _running = YES;
    return YES;
}

- (void)restart {
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    if (_ctx.unit && AudioOutputUnitStart(_ctx.unit) == noErr) { _running = YES; return; }
    [self buildUnit];
}

// ---- system events ----
- (void)interrupted:(NSNotification*)n {
    const NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    const NSUInteger reason = [n.userInfo[AVAudioSessionInterruptionReasonKey] unsignedIntegerValue];
    const NSUInteger opts = [n.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
    dispatch_async(_q, ^{
        if (type == AVAudioSessionInterruptionTypeBegan) { self->_running = NO; fm1log("interruption began (reason %lu)", (unsigned long)reason); [self retryLater]; }
        else { fm1log("interruption ended (options %lu)", (unsigned long)opts); [self restart]; }
    });
}
- (void)routeChanged:(NSNotification*)n {
    const NSUInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    dispatch_async(_q, ^{
        const double before = self->_hardwareRate;
        [self preferBuiltInMic];
        [self updateRoute];
        // A new device (the FM-1 plugged in or out) can bring another hardware rate: rebuild so the converter follows it.
        if ((reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable || reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) && before != self->_hardwareRate) {
            fm1log("hardware rate %.0f -> %.0f: rebuilding", before, self->_hardwareRate);
            [self buildUnit];
        }
    });
}
// An interruption whose end never comes (a call, another app that took the hardware): keep trying to come back while the app is in front.
- (void)retryLater {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), _q, ^{
        if (self->_running) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;   // the foreground notification restarts it
            dispatch_async(self->_q, ^{
                if (self->_running) return;
                NSError* e = nil;
                if ([[AVAudioSession sharedInstance] setActive:YES error:&e] && self->_ctx.unit && AudioOutputUnitStart(self->_ctx.unit) == noErr) {
                    self->_running = YES; fm1log("audio back after an interruption");
                } else { fm1log("still interrupted: %s", e.localizedDescription.UTF8String ?: "start failed"); [self retryLater]; }
            });
        });
    });
}

- (void)servicesReset:(NSNotification*)n {
    dispatch_async(_q, ^{
        fm1log("media services reset");
        self->_ctx.unit = nullptr;   // the old unit died with the server
        [self configureSession];
        [self buildUnit];
    });
}
// back in front: an interruption that never reported its end (another app took the audio) leaves the unit stopped
- (void)foreground:(NSNotification*)n { dispatch_async(_q, ^{ if (!self->_running) { fm1log("foreground: restarting"); [self restart]; } }); }
@end
