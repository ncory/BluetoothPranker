// Sound playback through the Atom Echo's built-in I2S amplifier + speaker.
// Clips live in LittleFS as 16-bit PCM WAV files; if a clip has not been
// uploaded, a built-in synthesized jingle is played instead.
#pragma once
#include <Arduino.h>
#include <FS.h>

enum Clip : uint8_t { CLIP_ENTER = 0, CLIP_LEAVE = 1 };

struct WavInfo {
    uint32_t sampleRate = 0;
    uint16_t channels   = 0;
    uint32_t dataOffset = 0;
    uint32_t dataBytes  = 0;
};

const char* clipPath(Clip c);
const char* clipName(Clip c);
bool        clipFromName(const char* name, Clip& out);
size_t      clipBytes(Clip c);  // 0 => no upload, built-in sound is used

bool wavParse(fs::File& f, WavInfo& out);  // only 16-bit PCM, mono/stereo, 8-48 kHz

void audioBegin();
void audioPlay(Clip c);  // non-blocking
void audioStop();
bool audioBusy();
