#pragma once
#include <stdint.h>
// The Atom's SK6812 is very bright; keep values low (0..40).
void ledSet(uint8_t r, uint8_t g, uint8_t b);
inline void ledOff() { ledSet(0, 0, 0); }
