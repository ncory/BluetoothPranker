#pragma once
#include <Arduino.h>

struct Settings {
    bool   armed       = true;   // master switch for playing sounds
    int    enterRssi   = -70;    // smoothed RSSI at/above this => "present"
    int    exitRssi    = -82;    // smoothed RSSI at/below this (for exitHoldSec) => "away"
    int    absenceSec  = 30;     // no packets for this long => "away"
    int    exitHoldSec = 8;      // how long the signal must stay weak before "away"
    float  smoothing   = 0.3f;   // EMA factor, 0.05 (very smooth) .. 1.0 (raw)
    int    cooldownSec = 20;     // minimum gap between any two sounds
    int    armDelaySec = 60;     // after power-on, stay silent this long (time to hide it)
    int    volume      = 80;     // 0..100
    bool   playEnter   = true;
    bool   playLeave   = true;
    int    chance      = 100;    // % chance a trigger actually plays (keeps them guessing)
    bool   led         = false;  // show presence on the LED (off = stealth)
    String name        = "Pranker";
};

extern Settings settings;

void   settingsLoad();
void   settingsSave();
String settingsToJson();
// Merges the given JSON into the settings (unknown keys ignored, values clamped).
// Returns false and sets err on malformed JSON.
bool   settingsApplyJson(const uint8_t* data, size_t len, String& err);

// One-shot request that makes the next boot enter enrollment mode for a
// target with the given name. enrollRequested() consumes the request.
void requestEnrollOnNextBoot(const char* targetName);
bool enrollRequested(String& targetName);

// Result of the last enrollment attempt, shown in the app.
enum EnrollResult : int { ENROLL_NONE = 0, ENROLL_OK = 1, ENROLL_TIMEOUT = 2, ENROLL_FAILED = 3, ENROLL_CANCELLED = 4, ENROLL_FULL = 5 };
void enrollResultSet(int r);
int  enrollResultGet();
