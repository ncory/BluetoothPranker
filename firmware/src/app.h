// Normal operating mode: scan for the target iPhone, play sounds on
// enter/leave, and expose the configuration service to the companion app.
#pragma once
#include <stdint.h>

void appBegin();
void appLoop();
void appTestPlay(bool enter);
void appStartEnrollment();  // reboots into enrollment mode
