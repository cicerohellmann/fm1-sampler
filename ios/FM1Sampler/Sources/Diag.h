// Diagnostics switches and the log. A switch is read from the launch environment or from Documents/diag.env (KEY=VALUE lines, so a test can
// be set up with `xcrun devicectl device copy to` when the app is started by hand). With FM1_DIAG set every log line also lands in
// Documents/diag/log.txt (copied back with `devicectl device copy from`). Without any switch nothing of this runs.
#pragma once
#import <Foundation/Foundation.h>

NSString* diagValue(NSString* key);                       // nil when the switch is not set
void fm1log(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void logMidiEndpoints(const char* who);                   // every CoreMIDI source / destination with its device's driver (FM1_DIAG)
