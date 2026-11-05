# BLE protocol (firmware ⇄ app)

The device advertises one 128-bit service and its name, which is configurable
and defaults to `Pranker`, in the scan response.

| Characteristic | UUID | Props | Content |
|---|---|---|---|
| Service | `b10e0000-7a5c-4f3b-9e2d-5c0ffee0b10e` | | |
| Config | `b10e0001-…` | read, write | settings JSON |
| Command | `b10e0002-…` | write | command JSON |
| Status | `b10e0003-…` | read, notify | status / info / event / ack JSON |
| Audio | `b10e0004-…` | write, write-no-rsp | upload chunks |
| Log | `b10e0005-…` | read | event log JSON |
| Targets | `b10e0006-…` | read | target list JSON |

All UUIDs share the suffix `-7a5c-4f3b-9e2d-5c0ffee0b10e`.

## Config (read/write)

```json
{"armed":true,"enter":-70,"exit":-82,"absence":30,"exitHold":8,"smooth":0.30,
 "cooldown":20,"armDelay":60,"vol":80,"playEnter":true,"playLeave":true,
 "chance":100,"led":false,"name":"Pranker"}
```

Writes are merged: unknown keys are ignored, values are clamped, the result
is saved to flash, and an `{"t":"ack","cmd":"config","ok":true}` follows.

## Targets (read)

`[{"id":1,"n":"Alex","on":1,"ce":96044,"cl":0}, ...]`. Each entry has a
stable `id`, a name (max 16 chars), enabled flag, and its custom clip sizes
(0 = uses the default). Up to 8 targets. Re-read whenever `tv` in the info
message changes.

## Clip ids

`enter` / `leave` are the default sounds. `t<id>e` / `t<id>l` are optional
per-target sounds. Playback falls back from the target clip, to the default
clip, to the built-in jingle.

## Commands (write)

| JSON | Effect |
|---|---|
| `{"cmd":"play","clip":"t2e"}` | Test a sound (with fallback) |
| `{"cmd":"stop"}` | Stop playback |
| `{"cmd":"hide"}` | Restart the silent hide timer |
| `{"cmd":"enroll","name":"Alex"}` | Reboot into enrollment (keyboard) mode for a new target |
| `{"cmd":"renameTarget","id":2,"name":"Al"}` | |
| `{"cmd":"enableTarget","id":2,"on":false}` | Pause/resume a target |
| `{"cmd":"removeTarget","id":2}` | Forget a target and its clips |
| `{"cmd":"upload","clip":"t2e","size":N,"crc":C}` | Start an upload (CRC-32, zlib) |
| `{"cmd":"delete","clip":"t2e"}` | Remove a custom clip |
| `{"cmd":"clearLog"}` / `{"cmd":"reboot"}` | |

Every command is answered on Status with `{"t":"ack","cmd":…,"ok":bool,"err"?:…}`.

## Status notifications

Every 500 ms while connected, one message per enabled target, then the
global one:

- `{"t":"p","id":2,"st":1,"r":-60,"s":-61.2,"age":120,"pps":1.2,"cd":0}`:
  present, last raw RSSI, smoothed RSSI, ms since last packet, packets/s, and
  cooldown seconds left.
- `{"t":"s","any":1,"cr":-55,"wait":0,"busy":0,"up":…,"upT":…}`: any target
  present, RSSI of the app's own connection, hide-timer seconds left,
  playing, upload progress.

Also:

- `{"t":"i", ...}` every 5 s and on change: `v` protocol version (2), `fw`,
  `nt` target count, `max`, `tv` target-list version, `ce`/`cl` default clip
  sizes, `free` flash bytes, `er` last enrollment result (0 none, 1 ok,
  2 timeout, 3 failed, 4 cancelled, 5 list full), `upt` uptime in seconds.
- `{"t":"e","id":2,"n":"Alex","ev":"enter"|"leave","played":bool,"why"?:…}` on every
  presence change. `why` is one of `disarmed`, `arming`, `off`, `cooldown`
  (per target), `chance`, `busy`.

## Upload

1. Send the `upload` command and wait for its ok ack.
2. Stream write-without-response chunks: `[uint32 LE offset][data]`. Offsets
   must be contiguous.
3. The device verifies CRC and WAV format, then acks `uploadDone`.

Format: 16-bit PCM WAV, mono or stereo, 8–48 kHz, at most 700 KB. The app
sends 16 kHz mono.

## Log (read)

`{"now":<device ms>,"ev":[[ms,targetId,enter(0/1),played(0/1)],...]}`, oldest first,
up to 20 entries, kept in RAM only.
