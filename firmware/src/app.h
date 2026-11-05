// Normal operating mode: scan for the target iPhones, play sounds on
// enter/leave, and expose the configuration service to the companion app.
#pragma once
#include <stdint.h>

void appBegin();
void appLoop();
void appTestPlay(int targetId, bool enter);
void appStartEnrollment(const char* targetName);  // reboots into enrollment mode
