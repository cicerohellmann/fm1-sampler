// Backend: owns the engine (Core), the audio (AudioIO) and the FM-1 link (MidiLink), and runs the surface thread (the Android ticker):
// app tick, SysEx out, link state, file requests.
#import <Foundation/Foundation.h>
#include <cstdint>

class Core;

@interface Backend : NSObject
+ (instancetype)shared;
- (void)start;
- (uint32_t)nowMs;                                   // the one clock of the app (ms since start): tick, UI frames and touches
@property (nonatomic, readonly) Core* core;
@property (nonatomic, readonly) NSString* dataDir;   // Documents: saved samples (sample_*.wav), the theme; visible in the Files app
@property (atomic, copy) void (^onFileRequest)(void);
@end
