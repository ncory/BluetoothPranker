# CLAUDE.md

Context for Claude Code sessions working on this repo. The user-facing
overview is in `README.md`. The BLE wire protocol is in `docs/PROTOCOL.md`.

## What this is

A hidden prank speaker: an **M5Stack Atom Echo** (ESP32-PICO-D4, built-in I2S
amp + speaker, button on GPIO39, SK6812 LED on GPIO27) plays a sound when an
enrolled iPhone arrives in or leaves a room. A **SwiftUI companion app**
configures it over BLE. The owner pranks a family member with their consent
to access the phone for the one-time pairing.

## Layout

```
firmware/                 PlatformIO project (Arduino framework)
  platformio.ini          env "atom-echo": espressif32@8.0.0 (Arduino core 3.x / IDF 5),
                          NimBLE-Arduino@2.5.2, ArduinoJson@7.4.3, LittleFS on default.csv
  src/main.cpp            boot, button (short = test sound, hold 3 s = enroll)
  src/app.cpp             normal mode: GATT service, scanning, presence, events, upload
  src/enroll.cpp          enrollment mode: poses as BLE HID keyboard to capture the IRK
  src/targets.cpp         up to 8 targets {id, name, enabled, IRK} in NVS
  src/presence.cpp        RSSI smoothing + enter/leave hysteresis state machine
  src/rpa.cpp             Resolvable Private Address matching (AES via mbedtls)
  src/audio.cpp           WAV playback via new I2S std driver, synth fallback jingles
  src/settings.cpp        settings JSON <-> NVS, enroll request flag, enroll result
  src/protocol.h          UUIDs, FW_VERSION, PROTOCOL_VERSION, pins
ios/
  BluetoothPranker.xcodeproj   hand-written, objectVersion 77 (Xcode 16+), uses a
                               file-system-synchronized group: new files in
                               ios/BluetoothPranker/ are picked up automatically
  BluetoothPranker/
    BLE/BLEManager.swift  CoreBluetooth central, @Observable @MainActor
    BLE/Models.swift      wire models, CRC32, calibration math
    BLE/DemoMode.swift    simulated device (Simulator has no Bluetooth)
    Audio/                clip conversion (16 kHz mono WAV), recorder, TTS, preview
    Views/                SwiftUI screens
docs/PROTOCOL.md          GATT characteristics, JSON messages, upload format
docs/mockups/             HTML-rendered mockups (NOT real screenshots)
```

## Build

- Firmware: `cd firmware && pio run` (build), `pio run -t upload`, `pio device monitor` (115200).
  It must compile with **no warnings in `src/`**. Verify after every firmware change.
- iOS: open `ios/BluetoothPranker.xcodeproj`, set Team and bundle id
  (placeholder `com.example.BluetoothPranker`), run on a device. iOS 17+,
  Swift 5 language mode (`SWIFT_VERSION = 5.0`), no third-party packages.
  In the Simulator use **Try demo mode** or launch argument `-demo`.

## Status: what's verified and what isn't

- Firmware **compiles cleanly** (flash ~77% of the 1.3 MB app partition). The
  RPA code passes the Bluetooth Core spec test vector (Vol 3 Part H D.7), and
  `rpaSelfTest()` re-runs it at boot.
- **Verified on a real Atom Echo (2026-11-10):** flashes over USB (FTDI
  `/dev/cu.usbserial-*`) and boots: `Bluetooth Pranker 1.2.0`,
  `RPA self-test: ok`, `[app] ready`.
- **Fixed on hardware:** the NimBLE host task (4 KB default) overflowed on
  the `upload` and `play` commands, because commands run in its write
  callback and touch LittleFS/ArduinoJson. `platformio.ini` now sets
  `CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE=8192`. After the fix, an upload and
  nine plays in a row ran without a crash. Watch for `Stack canary watchpoint
  triggered (nimble_host)` if commands grow.
- The **iOS app compiles** with Xcode 27.2 (iOS 27.2 SDK) with no errors or
  warnings, using the hand-written `project.pbxproj` as is. In the Simulator
  with `-demo`, every screen renders and the text-to-speech → convert →
  (simulated) upload flow works. It has **not run on a real iPhone yet**.
- **Not yet verified on real hardware.** Top risks to check first:
  1. **Enrollment — works (iPhone 18 Pro, iOS 27.2, 2026-11-10).** iOS
     listed the keyboard under Other Devices, paired, and shared its IRK. The
     IRK resolved the connection's RPA as stored (no byte reversal needed),
     and right after the reboot normal mode recognized the phone
     (`[event] Me (test) ENTER`). Caveat: on the first attempt the keyboard
     never appeared on the phone or a Mac, with no `[enroll] connected`; a
     retry with identical advertising code worked. The cause is unknown. If it
     recurs, check the `[enroll] … advertising ok` / `advertising=1` log lines.
  2. **Detection:** do iPhones' background advertisements resolve with that
     IRK, and how often do they arrive when the phone is locked (`pps` in
     status)?
  3. **Audio pins/format:** BCLK 19, LRCK 33, DOUT 22, stereo frames with the
     mono sample duplicated. Check loudness and that there's no idle hiss.
  4. **Upload — works (iOS 27.2).** No gaps, CRC and WAV checks pass, ~507-byte
     chunks at MTU 517. Throughput was only 2.5–4.5 KB/s because the 90%
     scan window starved the connection (see 6), and the app's fixed 20 s
     `uploadDone` timeout fired on bigger clips: the progress bar counts bytes
     handed to iOS, which buffers far ahead of the link. Now scanning pauses
     during uploads and the timeout scales with size: ~11.6 KB/s (75 KB in
     6.5 s). iOS kept a 30 ms interval when asked for 15–30 ms. Flash writes
     are ~19% of upload time; moving them off the host task is the next
     possible gain. `[upload] …` serial lines report bytes, time, chunks and
     flash time.
  5. **Long config writes** (> MTU) rely on prepared writes. iOS 27.2
     negotiated MTU 517, so a full config fits in one write.
  6. **Concurrent** advertising + passive scanning + one connection under
     NimBLE: works, but the scan starves the connection's throughput (see 4).
     Presence tracking pauses during an upload.

## Design decisions (and why)

- **Phone identification via IRK**: iPhones rotate their address about every
  15 min. Pairing once gives the device the phone's Identity Resolving Key.
  iOS only offers to pair with certain device types from Settings, hence the
  temporary HID keyboard persona (the same approach as the ESPresense
  project).
- **Enrollment is a separate boot mode with a random static address.** After
  enrolling, normal mode uses a different address, so the phone never
  auto-reconnects to the "keyboard". A connected keyboard would hide its
  on-screen keyboard and give the prank away. The user then taps *Forget This
  Device* on the phone. The phone's IRK should persist; only *Reset Network
  Settings* changes it. Verified on iOS 27.2: after *Forget This Device* the
  phone was still recognized. (While the app is connected, Settings lists
  that connection as "Connected" with no ⓘ; close the app to see the
  keyboard entry and forget it.)
- **Passive scan, duplicates on, no stored results.** Every advert updates
  RSSI. `RpaMatcher` caches hits/misses so AES only runs on new addresses.
- **Presence = EMA-smoothed RSSI with hysteresis.** Enter when smoothed ≥
  `enter`. Leave when ≤ `exit` for `exitHold` s, or when nothing is heard for
  `absence` s. Thresholds are global, not per target.
- **Gating order for a sound** (`handleEvent`): armed → hide timer (`armDelay`)
  → play toggle → per-target cooldown → random chance (`chanceIn`/`chanceOut`)
  → not already playing. A skipped event is still logged and notified, with a
  `why`.
- **Clip fallback**: `t<id>e/l.wav` → `enter/leave.wav` → synthesized jingle.
- **Threading (firmware)**: NimBLE callbacks run on the host task. The scan
  callback queues samples, and `appLoop` (Arduino loop task) owns presence.
  `s_lock` (recursive mutex) guards settings/targets/presence/log. **Never
  hold `s_lock` while calling into NimBLE** (notify etc.), to avoid deadlock.
  Target-list mutations happen on the host task, the same task as the scan
  callback.
- **Status split**: per-target `"p"` messages, then a global `"s"` (the app
  closes a chart sample on `"s"`). JSON messages stay under ~180 bytes so they
  fit a typical iOS MTU.
- **App calibration** can use an enrolled target (what the device really sees)
  or "this phone", meaning the app connection's RSSI (no enrollment needed).
- **Testing tip for the owner**: enroll their own phone as "Me (test)", then
  pause/remove it before the real prank. An unlocked phone in hand looks
  closer/faster than a locked phone in a pocket.
- Protocol changes must update **both** sides and `docs/PROTOCOL.md`, and bump
  `PROTOCOL_VERSION` when incompatible. The app rejects firmware without the
  Targets characteristic.

## Ideas not yet done (offered to the owner)

- Per-target random chance overrides (currently global arrival/departure chances).
- Per-target RSSI offset if phones differ.
- Battery/duty-cycled scanning for longer power-bank runtime.
- Persisting the event log across power loss (currently RAM, last 20).

## Conventions

- Commit messages: imperative subject, wrapped body explaining why.
- Keep firmware strings/JSON keys short. Keep the app's user-facing text
  friendly and gender-neutral (multiple targets).
- Don't commit `firmware/.pio/` or Xcode user data (see `.gitignore`).
