// Enrollment mode: the Atom pretends to be a Bluetooth keyboard so the target
// iPhone can pair with it from Settings > Bluetooth. During pairing the iPhone
// hands over its Identity Resolving Key (IRK), which we store. Afterwards the
// device reboots into normal mode with a different Bluetooth address, so the
// iPhone never reconnects to the "keyboard".
#pragma once

#include <Arduino.h>

[[noreturn]] void enrollRun(const String& targetName);
