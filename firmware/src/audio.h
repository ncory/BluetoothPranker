// Sound playback through the Atom Echo's built-in I2S amplifier + speaker.
// Clips live in LittleFS as 16-bit PCM WAV files; if a clip has not been
// uploaded, a built-in synthesized jingle is played instead.
#pragma once
#include <Arduino.h>
#include <FS.h>

// Clip ids used by the app: "enter" / "leave" are the defaults; "t<id>e" /
// "t<id>l" are optional per-target overrides. Playback falls back
// target clip -> default clip -> built-in jingle.

struct WavInfo {
    uint32_t sampleRate = 0;
    uint16_t channels   = 0;
    uint32_t dataOffset = 0;
    uint32_t dataBytes  = 0;
};

String clipPathForId(int targetId, bool enter);  // targetId 0 = default
inline String clipPathForTarget(int targetId, bool enter) { return clipPathForId(targetId, enter); }
bool   clipIdParse(const char* s, int& targetId, bool& enter);
size_t clipBytesPath(const String& path);  // 0 => no upload

bool wavParse(fs::File& f, WavInfo& out);  // only 16-bit PCM, mono/stereo, 8-48 kHz

void audioBegin();
void audioPlay(int targetId, bool enter);  // non-blocking
void audioStop();
bool audioBusy();
