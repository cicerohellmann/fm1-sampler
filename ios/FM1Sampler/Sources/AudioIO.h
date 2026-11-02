// AudioIO: the iOS counterpart of the Oboe streams of native-lib.cpp. One RemoteIO unit, 44.1 kHz float on the client side (iOS converts when
// the hardware runs at another rate; the FM-1's USB audio runs at 44.1 kHz, so through it nothing is converted). Output goes wherever iOS routes
// it (the FM-1 when it is plugged in, otherwise the speaker / headphones); the input is the phone's own microphone, never the USB device.
#import <Foundation/Foundation.h>

class Session;

@interface AudioIO : NSObject
- (instancetype)initWithSession:(Session*)session;
- (void)start;                                  // session setup, output at once, the microphone as soon as it is allowed
@property (atomic, readonly) BOOL usbOutput;    // the output route is a USB audio device (the FM-1)
@property (atomic, readonly) BOOL micRunning;
@property (atomic, readonly) double hardwareRate;
@property (nonatomic, readonly) uint64_t callbacks;   // render callbacks so far (diagnostics)
@property (nonatomic, readonly) NSString* inputStats;   // microphone FIFO: failed pulls, underruns, overruns (diagnostics)
@end
