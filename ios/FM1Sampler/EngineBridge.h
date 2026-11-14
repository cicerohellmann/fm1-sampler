#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C++ boundary for the shared C++ engine and iOS audio/MIDI services.
@interface EngineBridge : NSObject
- (instancetype)init;
- (NSDictionary<NSString *, id> *)frameWithWidth:(float)width height:(float)height top:(float)top bottom:(float)bottom now:(uint32_t)now;
- (void)touch:(int)action x:(float)x y:(float)y now:(uint32_t)now;
- (BOOL)takeFileRequest;
+ (NSDictionary<NSString *, NSString *> *)prepareSampleFromURL:(NSURL *)url;
- (void)loadImportedSample:(NSString *)path;
- (void)tick:(uint32_t)now;
- (void)refreshConnections;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
