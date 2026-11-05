// Bluetooth Pranker firmware for the M5Stack Atom Echo.
//
// Plays a sound when a specific iPhone comes into range ("enter") or leaves
// ("leave"). Configure and calibrate it with the iOS companion app.
//
// Button: short press = play the "enter" sound (test)
//         hold 3 s    = enrollment mode (pair the target iPhone)

#include <Arduino.h>
#include <LittleFS.h>

#include "app.h"
#include "audio.h"
#include "enroll.h"
#include "led.h"
#include "protocol.h"
#include "rpa.h"
#include "settings.h"

void setup() {
    Serial.begin(115200);
    pinMode(PIN_BUTTON, INPUT);  // GPIO39 has an external pull-up on the Atom
    setCpuFrequencyMhz(80);      // plenty for BLE + audio, saves battery
    ledSet(10, 10, 10);
    delay(150);
    ledOff();

    Serial.printf("\nBluetooth Pranker %s\n", FW_VERSION);
    Serial.printf("RPA self-test: %s\n", rpaSelfTest() ? "ok" : "FAILED");

    if (!LittleFS.begin(true)) Serial.println("LittleFS mount failed");
    settingsLoad();

    if (enrollRequested()) {
        requestEnrollOnNextBoot(false);  // one-shot, so a crash can't loop us here
        enrollRun();
    }

    audioBegin();
    appBegin();
}

void loop() {
    static uint32_t downAt  = 0;
    static bool     handled = false;
    bool            down    = digitalRead(PIN_BUTTON) == LOW;
    uint32_t        now     = millis();

    if (down) {
        if (!downAt) downAt = now;
        if (!handled && now - downAt >= 3000) {
            handled = true;
            ledSet(0, 0, 30);
            Serial.println("Long press: entering enrollment mode");
            appStartEnrollment();
        }
    } else {
        if (downAt && !handled && now - downAt >= 30) appTestPlay(true);
        downAt  = 0;
        handled = false;
    }

    appLoop();
    delay(20);
}
