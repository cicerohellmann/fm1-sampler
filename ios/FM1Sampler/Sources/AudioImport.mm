#import "AudioImport.h"
#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <vector>

static const double kMaxSeconds = 90;

@implementation AudioImport

+ (NSString*)baseName:(NSURL*)url {
    NSString* base = url.lastPathComponent.stringByDeletingPathExtension;
    NSMutableString* s = [NSMutableString string];
    for (NSUInteger i = 0; i < base.length; i++) {
        const unichar c = [base characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == ' ' || c == '_' || c == '-') [s appendFormat:@"%C", c];
    }
    NSString* t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return t.length ? t : @"import";
}

+ (NSString*)importURL:(NSURL*)url toDir:(NSString*)dir error:(NSError**)error {
    AVAudioFile* f = [[AVAudioFile alloc] initForReading:url commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:error];
    if (!f) return nil;
    const AVAudioFormat* fmt = f.processingFormat;
    const int chIn = (int)fmt.channelCount, ch = std::min(2, chIn);
    const double rate = fmt.sampleRate;
    if (ch < 1 || rate < 8000) { if (error) *error = [NSError errorWithDomain:@"import" code:1 userInfo:@{NSLocalizedDescriptionKey: @"no audio in the file"}]; return nil; }
    const AVAudioFrameCount chunk = 65536;
    AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:chunk];
    const int64_t maxFrames = (int64_t)(kMaxSeconds * rate);
    std::vector<int16_t> pcm;
    pcm.reserve((size_t)std::min<int64_t>(maxFrames, std::max<int64_t>(0, f.length)) * ch);
    int64_t frames = 0;
    while (frames < maxFrames) {
        NSError* e = nil;
        if (![f readIntoBuffer:buf frameCount:(AVAudioFrameCount)std::min<int64_t>(chunk, maxFrames - frames) error:&e]) {
            if (frames == 0) { if (error) *error = e; return nil; }
            break;   // a damaged tail: keep what was read
        }
        const AVAudioFrameCount n = buf.frameLength;
        if (n == 0) break;
        float* const* d = buf.floatChannelData;
        for (AVAudioFrameCount i = 0; i < n; i++)
            for (int c = 0; c < ch; c++) pcm.push_back((int16_t)std::lrintf(std::max(-1.f, std::min(1.f, d[c][i])) * 32767.f));
        frames += n;
    }
    if (pcm.empty()) { if (error) *error = [NSError errorWithDomain:@"import" code:2 userInfo:@{NSLocalizedDescriptionKey: @"no audio in the file"}]; return nil; }

    NSString* out = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"sample_%@.wav", [self baseName:url]]];
    FILE* o = fopen(out.fileSystemRepresentation, "wb");
    if (!o) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return nil; }
    auto u32 = [&](uint32_t v) { uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)}; fwrite(b, 1, 4, o); };
    auto u16 = [&](uint16_t v) { uint8_t b[2] = {(uint8_t)v, (uint8_t)(v >> 8)}; fwrite(b, 1, 2, o); };
    const uint32_t bytes = (uint32_t)(pcm.size() * 2), r = (uint32_t)std::lround(rate);
    fwrite("RIFF", 1, 4, o); u32(36 + bytes); fwrite("WAVEfmt ", 1, 8, o); u32(16); u16(1); u16((uint16_t)ch);
    u32(r); u32(r * ch * 2); u16((uint16_t)(ch * 2)); u16(16); fwrite("data", 1, 4, o); u32(bytes);
    static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "WAV data is little endian");
    fwrite(pcm.data(), sizeof(int16_t), pcm.size(), o);
    const bool ok = ferror(o) == 0;
    fclose(o);
    if (!ok) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]; return nil; }
    return out;
}
@end
