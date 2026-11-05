# Bluetooth Pranker

A tiny hidden speaker that plays a sound when a specific iPhone comes into
range or leaves. It runs on an **M5Stack Atom Echo** (ESP32 + speaker in a
24 mm cube) and comes with an **iOS companion app** for setup, calibration and
custom sounds.

```
firmware/   ESP32 firmware (PlatformIO, Arduino framework)
ios/        SwiftUI companion app (Xcode 16+, iOS 17+)
docs/       BLE protocol between the two
```

## How it works

iPhones change their Bluetooth address every ~15 minutes, but every address is
derived from the phone's **Identity Resolving Key (IRK)**. A phone hands its IRK
to devices it pairs with. So:

1. **Enrollment (once).** The Atom pretends to be a Bluetooth keyboard. You pair
   the target iPhone with it from *Settings › Bluetooth*, and it keeps the IRK.
   Then it reboots with a different address, so the iPhone never reconnects.
   You can then *Forget This Device* on the iPhone.
2. **Normal mode.** The Atom passively listens to Bluetooth advertisements. It
   recognizes the target iPhone by checking each address against the IRK, then
   tracks its signal strength (RSSI).
3. **Presence.** A smoothed RSSI above the *enter* threshold means "arrived".
   Below the *leave* threshold for a few seconds, or not heard at all for a
   while, means "left". The gap between the two thresholds stops it from
   flip-flopping at the doorway.
4. **Prank.** On arrive/leave it plays a sound. Hide timer, cooldown and random
   chance settings keep it unpredictable and give you time to hide it.

## What you need

- M5Stack Atom Echo
- A USB-C power bank. Prefer one with an "always on" or low-current mode,
  since some banks switch off when the load is small. Runtime is roughly
  1–2 days on 5,000 mAh.
- A Mac with Xcode 16 or later, and your Apple developer account

## Flash the firmware

Install [PlatformIO](https://platformio.org/install/cli) (or the VS Code
extension), plug in the Atom Echo, then:

```sh
cd firmware
pio run -t upload        # build + flash
pio device monitor       # optional: serial log at 115200 baud
```

Normal boot: the LED flashes white once, then blinks yellow every 3 s until a
target phone is enrolled. Pressing the button plays the "enter" sound.

## Build the app

Open `ios/BluetoothPranker.xcodeproj`. Under *Signing & Capabilities*, pick
your Team and change the bundle identifier (`com.example.BluetoothPranker`) to
something of yours. Then run it on your iPhone. Bluetooth doesn't work in the
simulator.

## Setup walkthrough

1. Open the app and tap your device to connect. The app remembers it and
   reconnects automatically from then on.
2. **Target phone → Start enrollment.** The Atom's LED pulses blue. On his
   unlocked iPhone, go to *Settings › Bluetooth*, tap the device under *Other
   Devices*, then tap *Pair*. Green means success. Then tap ⓘ › *Forget This
   Device* on his phone. Tip: rehearse with your own iPhone first.
3. **Calibrate range.** Choose *This phone* (no need for his phone). Measure
   once standing just inside the room and once just outside, then tap *Use
   these values*. Keep the phone in a pocket while measuring.
4. **Sounds.** Record your own, type text-to-speech, or import any audio file.
   Clips are converted on the phone to 16 kHz mono WAV, trimmed and normalized,
   then uploaded over Bluetooth.
5. **Hide it.** Tap *Start hide timer* (default 60 s of silence), stash the
   device and walk away. The live event list and *Event log* show what
   happened.

## Device controls

| Action | Result |
|---|---|
| Short press | Play the "enter" sound |
| Hold 3 s | Enrollment mode (LED pulses blue) |
| Press during enrollment | Cancel |

| LED | Meaning |
|---|---|
| White flash | Booted |
| Yellow blink every 3 s | No target phone enrolled yet |
| Pulsing blue | Enrollment: waiting for the iPhone to pair |
| Green / red (2 s) | Enrollment succeeded / failed |
| Off | Normal (stealth). Turn on "Show presence on LED" in Settings to debug. |

## Tuning notes

- **Leaving is slower than arriving.** Locked iPhones advertise less often,
  so "left" waits for a weak signal lasting *Weak signal must last*, or for
  *Gone after silence*. If you get false "left" events while he's still in
  the room, raise *Gone after silence*.
- **Walls help.** A doorway with a wall between the rooms gives a much
  sharper in/out difference than an open floor plan.
- **Placement.** Put the device on the "inside" side of the room, not next
  to the door, and not inside a closed metal or wooden box.
- If the Calibrate screen shows his phone isn't heard at all, re-enroll it.
  A *Reset Network Settings* on his phone creates a new IRK.

## Status

The firmware compiles (PlatformIO, espressif32 8.0.0, NimBLE-Arduino 2.5.2),
and the address-resolution code is checked against the Bluetooth spec's
test vector at every boot. The iOS app and the end-to-end flow haven't been
built or tested on real hardware yet, so expect a round of fixes.
