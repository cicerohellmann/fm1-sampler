#import "Diag.h"
#include <cstdarg>
#include <cstdio>
#include <mutex>
#include <os/log.h>
#import <CoreMIDI/CoreMIDI.h>

static NSDictionary<NSString*, NSString*>* switches() {
    static NSDictionary* d; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary* m = [NSMutableDictionary dictionary];
#if FM1_TEST_TOOLS
        NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* file = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"diag.env"] encoding:NSUTF8StringEncoding error:nil];
        for (NSString* line in [file componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            const NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound || [line hasPrefix:@"#"]) continue;
            m[[line substringToIndex:eq.location]] = [line substringFromIndex:eq.location + 1];
        }
        for (NSString* k in NSProcessInfo.processInfo.environment) if ([k hasPrefix:@"FM1_"]) m[k] = NSProcessInfo.processInfo.environment[k];
#else
        // Release: no switch is ever honoured (Documents is visible in the Files app, so diag.env must not be able to turn test hooks on)
        NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if ([NSFileManager.defaultManager fileExistsAtPath:[docs stringByAppendingPathComponent:@"diag.env"]]) os_log(OS_LOG_DEFAULT, "diag.env ignored: test tools are not part of this build");
#endif
        d = m;
    });
    return d;
}
NSString* diagValue(NSString* key) { NSString* v = switches()[key]; return v.length ? v : nil; }

static NSString* describe(MIDIEndpointRef e) {
    CFStringRef s = nullptr; NSString* name = @"?", *owner = @"-", *dname = @"-";
    if (MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s) == noErr && s) name = (__bridge_transfer NSString*)s;
    MIDIEntityRef ent = 0; MIDIDeviceRef dev = 0;
    if (MIDIEndpointGetEntity(e, &ent) == noErr && ent && MIDIEntityGetDevice(ent, &dev) == noErr && dev) {
        s = nullptr; if (MIDIObjectGetStringProperty(dev, kMIDIPropertyDriverOwner, &s) == noErr && s) owner = (__bridge_transfer NSString*)s;
        s = nullptr; if (MIDIObjectGetStringProperty(dev, kMIDIPropertyName, &s) == noErr && s) dname = (__bridge_transfer NSString*)s;
    }
    SInt32 off = 0; MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &off);
    return [NSString stringWithFormat:@"'%@' device '%@' driver %@%@", name, dname, owner, off ? @" OFFLINE" : @""];
}
void logMidiEndpoints(const char* who) {
    if (!diagValue(@"FM1_DIAG")) return;
    for (ItemCount i = 0; i < MIDIGetNumberOfSources(); i++) fm1log("%s: source %s", who, describe(MIDIGetSource(i)).UTF8String);
    for (ItemCount i = 0; i < MIDIGetNumberOfDestinations(); i++) fm1log("%s: destination %s", who, describe(MIDIGetDestination(i)).UTF8String);
    if (!MIDIGetNumberOfSources() && !MIDIGetNumberOfDestinations()) fm1log("%s: no MIDI endpoints", who);
}

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
