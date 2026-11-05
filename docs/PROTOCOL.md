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

All UUIDs share the suffix `-7a5c-4f3b-9e2d-5c0ffee0b10e`.

## Config (read/write)

```json
{"armed":true,"enter":-70,"exit":-82,"absence":30,"exitHold":8,"smooth":0.30,
 "cooldown":20,"armDelay":60,"vol":80,"playEnter":true,"playLeave":true,
 "chance":100,"led":false,"name":"Pranker"}
```

Writes are merged: unknown keys are ignored, values are clamped, the result
is saved to flash, and an `{"t":"ack","cmd":"config","ok":true}` follows.

## Commands (write)

| JSON | Effect |
|---|---|
| `{"cmd":"play","clip":"enter"\|"leave"}` | Test a sound |
| `{"cmd":"stop"}` | Stop playback |
| `{"cmd":"hide"}` | Restart the silent hide timer |
| `{"cmd":"enroll"}` | Reboot into enrollment (keyboard) mode |
| `{"cmd":"forget"}` | Delete the stored target IRK |
| `{"cmd":"upload","clip":"enter","size":N,"crc":C}` | Start an upload (CRC-32, zlib) |
| `{"cmd":"delete","clip":"enter"}` | Remove custom clip → built-in jingle |
| `{"cmd":"clearLog"}` / `{"cmd":"reboot"}` | |

Every command is answered on Status with `{"t":"ack","cmd":…,"ok":bool,"err"?:…}`.

## Status notifications

- `{"t":"s", ...}` every 500 ms while connected: `st` present (0/1), `r` last raw RSSI,
  `s` smoothed RSSI, `age` ms since last packet, `pps` packets/s, `cr` RSSI of
  the app's own connection, `wait` hide-timer seconds left, `cd` cooldown
  seconds left, `busy` playing, `up`/`upT` upload progress.
- `{"t":"i", ...}` every 5 s and on change: `v` protocol version, `fw`, `irk`
  (target enrolled), `ce`/`cl` custom clip sizes (0 = built-in), `free` flash
  bytes, `er` last enrollment result (0 none, 1 ok, 2 timeout, 3 failed,
  4 cancelled), `upt` uptime in seconds.
- `{"t":"e","ev":"enter"|"leave","played":bool,"why"?:…}` on every
  presence change. `why` is one of `disarmed`, `arming`, `off`, `cooldown`,
  `chance`, `busy`.

## Upload

1. Send the `upload` command and wait for its ok ack.
2. Stream write-without-response chunks: `[uint32 LE offset][data]`. Offsets
   must be contiguous.
3. The device verifies CRC and WAV format, then acks `uploadDone`.

Format: 16-bit PCM WAV, mono or stereo, 8–48 kHz, at most 700 KB. The app
sends 16 kHz mono.

## Log (read)

`{"now":<device ms>,"ev":[[ms,enter(0/1),played(0/1)],...]}`, oldest first,
up to 20 entries, kept in RAM only.
