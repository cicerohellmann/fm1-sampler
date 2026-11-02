#import "Diag.h"
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <os/log.h>

static NSDictionary<NSString*, NSString*>* switches() {
    static NSDictionary* d; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary* m = [NSMutableDictionary dictionary];
        NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* file = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"diag.env"] encoding:NSUTF8StringEncoding error:nil];
        for (NSString* line in [file componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            const NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound || [line hasPrefix:@"#"]) continue;
            m[[line substringToIndex:eq.location]] = [line substringFromIndex:eq.location + 1];
        }
        for (NSString* k in NSProcessInfo.processInfo.environment) if ([k hasPrefix:@"FM1_"]) m[k] = NSProcessInfo.processInfo.environment[k];
        d = m;
    });
    return d;
}
NSString* diagValue(NSString* key) { NSString* v = switches()[key]; return v.length ? v : nil; }

void fm1log(const char* fmt, ...) {
    static os_log_t log = os_log_create("ca.dallasgroot.fm1sampler", "app");
    static FILE* file = nullptr; static std::mutex mtx; static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!diagValue(@"FM1_DIAG")) return;
        NSString* dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"diag"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        file = fopen([dir stringByAppendingPathComponent:@"log.txt"].fileSystemRepresentation, "w");
    });
    char b[1024];
    va_list a; va_start(a, fmt); vsnprintf(b, sizeof b, fmt, a); va_end(a);
    os_log(log, "%{public}s", b);
    if (file) {
        std::lock_guard<std::mutex> l(mtx);
        fprintf(file, "%10.3f %s\n", NSProcessInfo.processInfo.systemUptime, b);
        fflush(file);
    }
}
