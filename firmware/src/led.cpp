#include "led.h"
#include <Arduino.h>
#include "protocol.h"

void ledSet(uint8_t r, uint8_t g, uint8_t b) {
    static int32_t last = -1;
    int32_t        c    = (r << 16) | (g << 8) | b;
    if (c == last) return;
    last = c;
    rgbLedWrite(PIN_LED, r, g, b);
}
