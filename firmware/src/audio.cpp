#include "audio.h"
#include <LittleFS.h>
#include <math.h>
#include "driver/i2s_std.h"
#include "protocol.h"
#include "settings.h"

static QueueHandle_t     s_queue;
static volatile bool     s_stop = false;
static volatile bool     s_busy = false;
static i2s_chan_handle_t s_tx   = nullptr;

static const int FRAMES = 256;
static int16_t   s_out[FRAMES * 2];  // stereo frames

struct PlayReq {
    uint8_t targetId;
    bool    enter;
};

String clipPathForId(int targetId, bool enter) {
    if (targetId <= 0) return enter ? "/enter.wav" : "/leave.wav";
    return "/t" + String(targetId) + (enter ? "e" : "l") + ".wav";
}

bool clipIdParse(const char* s, int& targetId, bool& enter) {
    if (!s) return false;
    if (!strcmp(s, "enter")) { targetId = 0; enter = true; return true; }
    if (!strcmp(s, "leave")) { targetId = 0; enter = false; return true; }
    if (s[0] != 't') return false;
    char* end;
    long  id = strtol(s + 1, &end, 10);
    if (end == s + 1 || id < 1 || id > 255) return false;
    if (!strcmp(end, "e")) enter = true;
    else if (!strcmp(end, "l")) enter = false;
    else return false;
    targetId = (int)id;
    return true;
}

size_t clipBytesPath(const String& path) {
    if (!LittleFS.exists(path)) return 0;
    File   f = LittleFS.open(path, "r");
    size_t n = f ? f.size() : 0;
    f.close();
    return n;
}

static uint16_t rd16(const uint8_t* p) { return p[0] | (p[1] << 8); }
static uint32_t rd32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

bool wavParse(fs::File& f, WavInfo& w) {
    uint8_t h[12];
    size_t  size = f.size();
    if (!f.seek(0) || f.read(h, 12) != 12) return false;
    if (memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) return false;

    bool     haveFmt = false;
    uint16_t format = 0, bits = 0;
    uint32_t pos = 12;
    while (pos + 8 <= size) {
        uint8_t ch[8];
        f.seek(pos);
        if (f.read(ch, 8) != 8) return false;
        uint32_t len = rd32(ch + 4);
        if (!memcmp(ch, "fmt ", 4)) {
            uint8_t b[16];
            if (len < 16 || f.read(b, 16) != 16) return false;
            format       = rd16(b);
            w.channels   = rd16(b + 2);
            w.sampleRate = rd32(b + 4);
            bits         = rd16(b + 14);
            haveFmt      = true;
        } else if (!memcmp(ch, "data", 4)) {
            w.dataOffset = pos + 8;
            w.dataBytes  = min<uint32_t>(len, size - w.dataOffset);
            return haveFmt && (format == 1 || format == 0xFFFE) && bits == 16 &&
                   (w.channels == 1 || w.channels == 2) && w.sampleRate >= 8000 && w.sampleRate <= 48000;
        }
        pos += 8 + len + (len & 1);
    }
    return false;
}

static bool i2sOpen(uint32_t rate) {
    i2s_chan_config_t cc = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0, I2S_ROLE_MASTER);
    cc.auto_clear        = true;
    if (i2s_new_channel(&cc, &s_tx, nullptr) != ESP_OK) return false;

    i2s_std_config_t sc = {};
    sc.clk_cfg  = I2S_STD_CLK_DEFAULT_CONFIG(rate);
    sc.slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO);
    sc.gpio_cfg.mclk = I2S_GPIO_UNUSED;
    sc.gpio_cfg.bclk = (gpio_num_t)PIN_I2S_BCLK;
    sc.gpio_cfg.ws   = (gpio_num_t)PIN_I2S_LRCK;
    sc.gpio_cfg.dout = (gpio_num_t)PIN_I2S_DOUT;
    sc.gpio_cfg.din  = I2S_GPIO_UNUSED;
    if (i2s_channel_init_std_mode(s_tx, &sc) != ESP_OK || i2s_channel_enable(s_tx) != ESP_OK) {
        i2s_del_channel(s_tx);
        s_tx = nullptr;
        return false;
    }
    return true;
}

static void i2sWrite(const int16_t* stereo, size_t frames) {
    size_t written;
    i2s_channel_write(s_tx, stereo, frames * 4, &written, portMAX_DELAY);
}

static void i2sClose() {
    memset(s_out, 0, sizeof(s_out));
    for (int i = 0; i < 4; i++) i2sWrite(s_out, FRAMES);  // flush DMA with silence (less pop)
    i2s_channel_disable(s_tx);
    i2s_del_channel(s_tx);
    s_tx = nullptr;
}

// Perceptual volume curve: 0..100 -> 0..4096 (Q12 gain)
static int32_t gainQ12() {
    int v = settings.volume;
    return (int32_t)v * v * 4096 / 10000;
}

static inline int16_t applyGain(int32_t s, int32_t g) {
    s = (s * g) >> 12;
    return (int16_t)(s > 32767 ? 32767 : (s < -32768 ? -32768 : s));
}

static bool playFile(const String& path) {
    if (!LittleFS.exists(path)) return false;
    File f = LittleFS.open(path, "r");
    if (!f) return false;
    WavInfo w;
    if (!wavParse(f, w) || !i2sOpen(w.sampleRate)) {
        f.close();
        return false;
    }
    f.seek(w.dataOffset);
    int16_t  in[FRAMES * 2];
    uint32_t remaining = w.dataBytes;
    int32_t  g         = gainQ12();
    size_t   frameSize = 2 * w.channels;
    while (remaining >= frameSize && !s_stop) {
        size_t want = min<uint32_t>(remaining, FRAMES * frameSize);
        want -= want % frameSize;
        size_t got = f.read((uint8_t*)in, want);
        if (got < frameSize) break;
        size_t frames = got / frameSize;
        for (size_t i = 0; i < frames; i++) {
            int32_t s = w.channels == 1 ? in[i] : ((int32_t)in[2 * i] + in[2 * i + 1]) / 2;
            int16_t o = applyGain(s, g);
            s_out[2 * i] = s_out[2 * i + 1] = o;  // same signal on both slots
        }
        i2sWrite(s_out, frames);
        remaining -= got;
    }
    f.close();
    i2sClose();
    return true;
}

// Built-in fallback: a cheerful rising "ta-da" for enter, a sad descending
// "wah wah wah" for leave.
static void playSynth(bool enter) {
    const uint32_t rate = 16000;
    static const float enterNotes[] = {523.25f, 659.25f, 783.99f, 1046.5f};  // C5 E5 G5 C6
    static const float leaveNotes[] = {392.00f, 369.99f, 349.23f, 329.63f};  // G4 F#4 F4 E4
    const float*   notes  = enter ? enterNotes : leaveNotes;
    const float    durSec[] = {0.12f, 0.12f, 0.12f, 0.45f};
    const float    leaveDur[] = {0.35f, 0.35f, 0.35f, 0.9f};
    if (!i2sOpen(rate)) return;
    int32_t g     = gainQ12();
    float   phase = 0;
    for (int n = 0; n < 4 && !s_stop; n++) {
        float    d      = enter ? durSec[n] : leaveDur[n];
        uint32_t total  = (uint32_t)(d * rate);
        float    f0     = notes[n];
        uint32_t i      = 0;
        while (i < total && !s_stop) {
            size_t frames = min<uint32_t>(FRAMES, total - i);
            for (size_t k = 0; k < frames; k++, i++) {
                float t   = (float)i / rate;
                float env = min(1.0f, t * 200.0f) * expf(-t * (enter ? 6.0f : 2.5f));
                float f   = enter ? f0 : f0 * (1.0f + 0.03f * sinf(2 * PI * 6 * t));  // wobble
                phase += 2 * PI * f / rate;
                if (phase > 2 * PI) phase -= 2 * PI;
                // a bit of 2nd harmonic makes it audible on a tiny speaker
                float   v = 0.6f * sinf(phase) + 0.25f * sinf(2 * phase);
                int16_t o = applyGain((int32_t)(v * env * 30000), g);
                s_out[2 * k] = s_out[2 * k + 1] = o;
            }
            i2sWrite(s_out, frames);
        }
    }
    i2sClose();
}

static void audioTask(void*) {
    PlayReq r;
    for (;;) {
        if (xQueueReceive(s_queue, &r, portMAX_DELAY) != pdTRUE) continue;
        s_busy = true;
        s_stop = false;
        bool played = r.targetId && playFile(clipPathForId(r.targetId, r.enter));
        if (!played) played = playFile(clipPathForId(0, r.enter));
        if (!played) playSynth(r.enter);
        s_busy = false;
    }
}

void audioBegin() {
    s_queue = xQueueCreate(2, sizeof(PlayReq));
    xTaskCreatePinnedToCore(audioTask, "audio", 6144, nullptr, 3, nullptr, 1);
}

void audioPlay(int targetId, bool enter) {
    if (s_busy) return;  // don't stack sounds
    PlayReq r{(uint8_t)max(0, targetId), enter};
    xQueueSend(s_queue, &r, 0);
}

void audioStop() { s_stop = true; }
bool audioBusy() { return s_busy || uxQueueMessagesWaiting(s_queue) > 0; }
