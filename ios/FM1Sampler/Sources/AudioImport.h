// A file picked from the disk -> a 16-bit PCM WAV in the data dir (sample_<name>.wav = the "User" group of the library).
// AVAudioFile decodes whatever iOS can read (wav, aiff, caf, mp3, aac / m4a, alac, flac...). At most 90 s, at most two channels.
#import <Foundation/Foundation.h>

@interface AudioImport : NSObject
+ (nullable NSString*)importURL:(nonnull NSURL*)url toDir:(nonnull NSString*)dir error:(NSError* _Nullable* _Nullable)error;
@end
