// Core: Session + SamplerApp + SamplerUI behind one mutex, the iOS counterpart of android/.../native-lib.cpp (minus the audio stream,
// which lives in AudioIO). CoreMIDI feeds the FM-1's bytes in, the surface thread ticks the app and takes the SysEx bytes to send out.
#pragma once
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <UiOp.h>
#include <functional>
#include <SamplerUI.h>
using SamplerUIExtraRow = SamplerUI::ExtraRow;

class Session;
class SamplerApp;
class SamplerUI;

class Core {
public:
    Core(const std::string& dataDir, const std::string& sampleDir);
    ~Core();
    Session& session() { return *session_; }

    void midiIn(const uint8_t* d, size_t n);         // raw MIDI 1.0 bytes from the FM-1 (any chunking; SysEx may span calls)
    std::vector<uint8_t> tick(uint32_t nowMs);       // ~60 Hz: runs the app, returns the SysEx bytes it wants sent to the FM-1
    bool wantFile();                                 // the phone UI asked for the disk picker
    void importFile(const std::string& wavPath);     // a picked file, already converted to a 16-bit WAV in the data dir
    void say(const std::string& msg);                // a toast in the header
    void uiLink(bool midi, bool usbAudio);
    void uiFrame(float w, float h, uint32_t nowMs, std::vector<UiOp>& out);   // the draw ops of one frame (copied out under the lock)
    void uiTouch(int action /*0 down 1 move 2 up*/, float x, float y, uint32_t nowMs);
    void playNote(int note, bool down);              // as if a key of the FM-1 was pressed (diagnostics script)
    bool micTakeWaiting();                           // a microphone take is armed / running (SAVE page MIC SAMPLE, or the loop with LOOP SOURCE = MIC)
    void cancelMicTake();                            // ends a MIC SAMPLE take that is only waiting for sound
    std::string diagLine();                          // one line of engine state for the log (diagnostics)
    void setExtraRows(std::function<std::vector<SamplerUIExtraRow>()> rows);   // rows at the end of the PROJECT menu (SamplerUI::setExtraRows)

private:
    std::unique_ptr<Session> session_;
    std::unique_ptr<SamplerApp> app_;
    std::unique_ptr<SamplerUI> ui_;
    std::mutex mtx_;
    std::vector<uint8_t> out_;
    std::vector<uint8_t> sx_; bool inSx_ = false;
    uint8_t msg_[3] = {0, 0, 0}; int msgLen_ = 0, msgNeed_ = 3;
};
