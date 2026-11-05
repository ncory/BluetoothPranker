// BLE protocol shared with the iOS companion app (see ../../docs/PROTOCOL.md).
#pragma once

#define FW_VERSION "1.0.0"
#define PROTOCOL_VERSION 1

#define SVC_UUID       "b10e0000-7a5c-4f3b-9e2d-5c0ffee0b10e"
#define CHR_CONFIG     "b10e0001-7a5c-4f3b-9e2d-5c0ffee0b10e"  // read/write JSON settings
#define CHR_COMMAND    "b10e0002-7a5c-4f3b-9e2d-5c0ffee0b10e"  // write JSON command
#define CHR_STATUS     "b10e0003-7a5c-4f3b-9e2d-5c0ffee0b10e"  // read/notify JSON status + events
#define CHR_AUDIO      "b10e0004-7a5c-4f3b-9e2d-5c0ffee0b10e"  // write-without-response upload chunks
#define CHR_LOG        "b10e0005-7a5c-4f3b-9e2d-5c0ffee0b10e"  // read JSON event log

// M5Stack Atom Echo pinout
#define PIN_BUTTON   39
#define PIN_LED      27
#define PIN_I2S_BCLK 19
#define PIN_I2S_LRCK 33
#define PIN_I2S_DOUT 22
