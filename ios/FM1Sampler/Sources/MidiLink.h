// MidiLink: the FM-1 over CoreMIDI (USB class compliant MIDI through the iPhone's USB-C port), the counterpart of Backend.java's MIDI part.
// Finds the FM-1 by name, follows plug / unplug, hands its bytes (MIDI 1.0 byte stream) to the receiver and sends SysEx to it.
#import <Foundation/Foundation.h>
#include <cstddef>
#include <cstdint>

typedef void (^MidiReceiver)(const uint8_t* bytes, size_t n);

@interface MidiLink : NSObject
- (instancetype)initWithReceiver:(MidiReceiver)rx;
- (void)start;                                          // main thread
- (void)send:(const uint8_t*)bytes length:(size_t)n;    // complete SysEx messages (F0 .. F7), any thread
@property (atomic, readonly) BOOL connected;            // a destination to the FM-1 is open
@property (atomic, readonly, copy) NSString* deviceName;
@property (atomic, readonly) BOOL bluetooth;               // the FM-1 port is Bluetooth MIDI
@end
