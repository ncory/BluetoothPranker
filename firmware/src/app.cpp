#include "app.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <NimBLEDevice.h>

#include "audio.h"
#include "led.h"
#include "presence.h"
#include "protocol.h"
#include "rpa.h"
#include "settings.h"

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

struct Sample {
    int8_t   rssi;
    uint32_t ms;
};

struct LogEntry {
    uint32_t ms;
    uint8_t  enter;
    uint8_t  played;
};

static const int     LOG_MAX = 20;
static LogEntry      s_log[LOG_MAX];
static int           s_logCount = 0, s_logNext = 0;

static QueueHandle_t     s_samples;
static SemaphoreHandle_t s_lock;  // guards settings, presence, log
static RpaMatcher        s_matcher;
static Presence          s_presence;

static NimBLEServer*         s_server;
static NimBLEScan*           s_scan;
static NimBLECharacteristic *s_chConfig, *s_chCommand, *s_chStatus, *s_chAudio, *s_chLog;
static volatile uint16_t     s_conn = BLE_HS_CONN_HANDLE_NONE;

static uint32_t      s_armStart   = 0;
static uint32_t      s_lastPlay   = 0;
static bool          s_everPlayed = false;
static volatile bool s_infoDirty  = true;
static uint32_t      s_rebootAt   = 0;
static int           s_enrollRes  = 0;

static struct {
    bool     active = false;
    Clip     clip;
    uint32_t size = 0, crc = 0, received = 0, runningCrc = 0;
    File     file;
} s_up;

static const uint32_t MAX_CLIP_BYTES = 700 * 1024;

struct Lock {
    Lock() { xSemaphoreTakeRecursive(s_lock, portMAX_DELAY); }
    ~Lock() { xSemaphoreGiveRecursive(s_lock); }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static uint32_t crc32Update(uint32_t crc, const uint8_t* d, size_t n) {
    crc = ~crc;
    while (n--) {
        crc ^= *d++;
        for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

static void sendJson(JsonDocument& doc) {
    String s;
    serializeJson(doc, s);
    // No s_lock here: never hold our lock while calling into the BLE host.
    s_chStatus->setValue(s);
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) s_chStatus->notify();
}

static void ack(const char* cmd, bool ok, const char* err = nullptr) {
    JsonDocument d;
    d["t"]   = "ack";
    d["cmd"] = cmd;
    d["ok"]  = ok;
    if (err) d["err"] = err;
    sendJson(d);
}

static uint32_t armRemainingMs(uint32_t now) {
    uint32_t delay = (uint32_t)settings.armDelaySec * 1000;
    uint32_t el    = now - s_armStart;
    return el >= delay ? 0 : delay - el;
}

static uint32_t cooldownRemainingMs(uint32_t now) {
    if (!s_everPlayed) return 0;
    uint32_t cd = (uint32_t)settings.cooldownSec * 1000;
    uint32_t el = now - s_lastPlay;
    return el >= cd ? 0 : cd - el;
}

static void setupAdvertising() {
    NimBLEAdvertising*      adv = NimBLEDevice::getAdvertising();
    NimBLEAdvertisementData ad, sr;
    ad.setFlags(BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP);
    ad.setCompleteServices(NimBLEUUID(SVC_UUID));
    sr.setName(settings.name.c_str());
    adv->setAdvertisementData(ad);
    adv->setScanResponseData(sr);
    adv->enableScanResponse(true);
    adv->setMinInterval(800);  // 500 ms (units of 0.625 ms): low power, still quick to find
    adv->setMaxInterval(960);
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

static void handleEvent(PresenceEvent e, uint32_t now) {
    bool        enter  = e == PresenceEvent::Enter;
    bool        played = false;
    const char* why    = nullptr;

    if (!settings.armed) why = "disarmed";
    else if (armRemainingMs(now) > 0) why = "arming";
    else if (enter ? !settings.playEnter : !settings.playLeave) why = "off";
    else if (cooldownRemainingMs(now) > 0) why = "cooldown";
    else if ((int)random(100) >= settings.chance) why = "chance";
    else if (audioBusy()) why = "busy";
    else {
        audioPlay(enter ? CLIP_ENTER : CLIP_LEAVE);
        s_lastPlay   = now;
        s_everPlayed = true;
        played       = true;
    }

    {
        Lock l;
        s_log[s_logNext] = {now, (uint8_t)enter, (uint8_t)played};
        s_logNext        = (s_logNext + 1) % LOG_MAX;
        if (s_logCount < LOG_MAX) s_logCount++;
    }

    Serial.printf("[event] %s played=%d %s\n", enter ? "ENTER" : "LEAVE", played, why ? why : "");

    JsonDocument d;
    d["t"]      = "e";
    d["ev"]     = enter ? "enter" : "leave";
    d["played"] = played;
    if (why) d["why"] = why;
    sendJson(d);
}

// ---------------------------------------------------------------------------
// Upload of sound clips (called on the NimBLE host task)
// ---------------------------------------------------------------------------

static void uploadAbort(const char* why) {
    if (s_up.active) {
        s_up.file.close();
        LittleFS.remove("/upload.tmp");
    }
    s_up.active = false;
    s_infoDirty = true;
    if (why) ack("upload", false, why);
}

static void uploadBegin(JsonDocument& doc) {
    if (s_up.active) uploadAbort(nullptr);
    Clip c;
    if (!clipFromName(doc["clip"].as<const char*>(), c)) return ack("upload", false, "bad clip");
    uint32_t size = doc["size"] | 0u;
    uint32_t crc  = doc["crc"] | 0u;
    if (size < 44 || size > MAX_CLIP_BYTES) return ack("upload", false, "bad size");

    size_t freeBytes = LittleFS.totalBytes() - LittleFS.usedBytes() + clipBytes(c);
    if (size + 16 * 1024 > freeBytes) return ack("upload", false, "not enough space");

    // Remove the old clip first so its space is available.
    LittleFS.remove(clipPath(c));
    s_up.file = LittleFS.open("/upload.tmp", "w");
    if (!s_up.file) return ack("upload", false, "fs error");
    s_up.active     = true;
    s_up.clip       = c;
    s_up.size       = size;
    s_up.crc        = crc;
    s_up.received   = 0;
    s_up.runningCrc = 0;
    s_infoDirty     = true;
    ack("upload", true);  // "ready"; the app now streams chunks
}

static void uploadFinish() {
    s_up.file.close();
    s_up.active = false;
    s_infoDirty = true;

    if (s_up.runningCrc != s_up.crc) {
        LittleFS.remove("/upload.tmp");
        return ack("uploadDone", false, "crc mismatch");
    }
    File    f = LittleFS.open("/upload.tmp", "r");
    WavInfo w;
    bool    ok = f && wavParse(f, w);
    f.close();
    if (!ok) {
        LittleFS.remove("/upload.tmp");
        return ack("uploadDone", false, "not a 16-bit PCM wav");
    }
    LittleFS.rename("/upload.tmp", clipPath(s_up.clip));
    ack("uploadDone", true);
}

// Chunk format: [uint32 LE offset][data...]
static void uploadChunk(const uint8_t* d, size_t n) {
    if (!s_up.active || n < 5) return;
    uint32_t off = d[0] | (d[1] << 8) | (d[2] << 16) | ((uint32_t)d[3] << 24);
    if (off != s_up.received) {
        char msg[48];
        snprintf(msg, sizeof msg, "gap at %u (got %u)", (unsigned)s_up.received, (unsigned)off);
        return uploadAbort(msg);
    }
    size_t len = min<size_t>(n - 4, s_up.size - s_up.received);
    if (s_up.file.write(d + 4, len) != len) return uploadAbort("write failed (disk full?)");
    s_up.runningCrc = crc32Update(s_up.runningCrc, d + 4, len);
    s_up.received  += len;
    if (s_up.received >= s_up.size) uploadFinish();
}

// ---------------------------------------------------------------------------
// Commands (called on the NimBLE host task)
// ---------------------------------------------------------------------------

static void handleCommand(const uint8_t* data, size_t len) {
    JsonDocument doc;
    if (deserializeJson(doc, data, len)) return ack("?", false, "bad json");
    const char* cmd = doc["cmd"] | "";
    Serial.printf("[cmd] %s\n", cmd);

    if (!strcmp(cmd, "play")) {
        Clip c = CLIP_ENTER;
        clipFromName(doc["clip"].as<const char*>(), c);
        audioPlay(c);
        ack(cmd, true);
    } else if (!strcmp(cmd, "stop")) {
        audioStop();
        ack(cmd, true);
    } else if (!strcmp(cmd, "enroll")) {
        ack(cmd, true);
        appStartEnrollment();
    } else if (!strcmp(cmd, "forget")) {
        Lock l;
        irkClear();
        s_matcher.clear();
        s_presence.reset();
        s_infoDirty = true;
        ack(cmd, true);
    } else if (!strcmp(cmd, "upload")) {
        uploadBegin(doc);
    } else if (!strcmp(cmd, "delete")) {
        Clip c;
        if (!clipFromName(doc["clip"].as<const char*>(), c)) return ack(cmd, false, "bad clip");
        LittleFS.remove(clipPath(c));
        s_infoDirty = true;
        ack(cmd, true);
    } else if (!strcmp(cmd, "hide")) {
        // Restart the silent arming period, e.g. right before hiding the device.
        Lock l;
        s_armStart = millis();
        ack(cmd, true);
    } else if (!strcmp(cmd, "clearLog")) {
        Lock l;
        s_logCount = s_logNext = 0;
        ack(cmd, true);
    } else if (!strcmp(cmd, "reboot")) {
        ack(cmd, true);
        s_rebootAt = millis() + 500;
    } else {
        ack(cmd, false, "unknown command");
    }
}

// ---------------------------------------------------------------------------
// BLE callbacks
// ---------------------------------------------------------------------------

class ServerCB : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer*, NimBLEConnInfo& ci) override {
        s_conn      = ci.getConnHandle();
        s_infoDirty = true;
        Serial.printf("[ble] app connected %s\n", ci.getAddress().toString().c_str());
    }
    void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        if (s_up.active) uploadAbort(nullptr);
        Serial.printf("[ble] app disconnected (%d)\n", reason);
    }
    void onMTUChange(uint16_t mtu, NimBLEConnInfo&) override { Serial.printf("[ble] MTU %u\n", mtu); }
};

class ConfigCB : public NimBLECharacteristicCallbacks {
    void onRead(NimBLECharacteristic* c, NimBLEConnInfo&) override {
        Lock l;
        c->setValue(settingsToJson());
    }
    void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
        NimBLEAttValue v = c->getValue();
        String         err;
        bool           ok;
        bool           nameChanged;
        {
            Lock   l;
            String oldName = settings.name;
            ok             = settingsApplyJson(v.data(), v.size(), err);
            nameChanged    = settings.name != oldName;
            if (ok) settingsSave();
            c->setValue(settingsToJson());
        }
        if (ok && nameChanged) setupAdvertising();
        ack("config", ok, ok ? nullptr : err.c_str());
    }
};

class CommandCB : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
        NimBLEAttValue v = c->getValue();
        handleCommand(v.data(), v.size());
    }
};

class AudioCB : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c, NimBLEConnInfo&) override {
        NimBLEAttValue v = c->getValue();
        uploadChunk(v.data(), v.size());
    }
};

class LogCB : public NimBLECharacteristicCallbacks {
    void onRead(NimBLECharacteristic* c, NimBLEConnInfo&) override {
        // {"now":<ms>,"ev":[[ms,enter,played],...]} oldest first. The app turns
        // the ms values into wall-clock times using "now".
        JsonDocument d;
        Lock         l;
        d["now"]      = millis();
        JsonArray arr = d["ev"].to<JsonArray>();
        int       start = (s_logNext - s_logCount + LOG_MAX) % LOG_MAX;
        for (int i = 0; i < s_logCount; i++) {
            const LogEntry& e = s_log[(start + i) % LOG_MAX];
            JsonArray       a = arr.add<JsonArray>();
            a.add(e.ms);
            a.add(e.enter);
            a.add(e.played);
        }
        String s;
        serializeJson(d, s);
        c->setValue(s);
    }
};

class ScanCB : public NimBLEScanCallbacks {
    void onResult(const NimBLEAdvertisedDevice* dev) override {
        const NimBLEAddress& a = dev->getAddress();
        if (s_matcher.matches(a.getType(), a.getVal())) {
            Sample s{(int8_t)dev->getRSSI(), millis()};
            xQueueSend(s_samples, &s, 0);
        }
    }
};

// ---------------------------------------------------------------------------
// Public
// ---------------------------------------------------------------------------

void appStartEnrollment() {
    requestEnrollOnNextBoot(true);
    s_rebootAt = millis() + 600;
}

void appTestPlay(bool enter) { audioPlay(enter ? CLIP_ENTER : CLIP_LEAVE); }

void appBegin() {
    s_lock      = xSemaphoreCreateRecursiveMutex();
    s_samples   = xQueueCreate(64, sizeof(Sample));
    s_armStart  = millis();
    s_enrollRes = enrollResultGet();

    uint8_t irk[16];
    if (irkLoad(irk)) {
        s_matcher.setIrk(irk);
        Serial.println("[app] target IRK loaded");
    } else {
        Serial.println("[app] no target enrolled yet");
    }

    NimBLEDevice::init(settings.name.c_str());
    NimBLEDevice::setPower(9);  // dBm, max
    NimBLEDevice::setMTU(517);
    // We never need bonds in normal mode.
    NimBLEDevice::deleteAllBonds();

    s_server = NimBLEDevice::createServer();
    s_server->setCallbacks(new ServerCB());
    s_server->advertiseOnDisconnect(true);

    NimBLEService* svc = s_server->createService(SVC_UUID);
    s_chConfig  = svc->createCharacteristic(CHR_CONFIG, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE, 512);
    s_chCommand = svc->createCharacteristic(CHR_COMMAND, NIMBLE_PROPERTY::WRITE, 512);
    s_chStatus  = svc->createCharacteristic(CHR_STATUS, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY, 512);
    s_chAudio   = svc->createCharacteristic(CHR_AUDIO, NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE, 512);
    s_chLog     = svc->createCharacteristic(CHR_LOG, NIMBLE_PROPERTY::READ, 512);
    s_chConfig->setCallbacks(new ConfigCB());
    s_chCommand->setCallbacks(new CommandCB());
    s_chAudio->setCallbacks(new AudioCB());
    s_chLog->setCallbacks(new LogCB());
    s_chConfig->setValue(settingsToJson());
    s_chStatus->setValue("{}");
    s_server->start();

    setupAdvertising();
    NimBLEDevice::startAdvertising();

    s_scan = NimBLEDevice::getScan();
    s_scan->setScanCallbacks(new ScanCB(), /*wantDuplicates=*/true);
    s_scan->setActiveScan(false);  // passive: we only need the RSSI
    s_scan->setInterval(100);
    s_scan->setWindow(90);
    s_scan->setMaxResults(0);  // don't keep results in RAM

    Serial.printf("[app] ready, BLE address %s\n", NimBLEDevice::getAddress().toString().c_str());
}

static void sendStatus(uint32_t now) {
    JsonDocument d;
    {
        Lock l;
        d["t"]  = "s";
        d["st"] = s_presence.present() ? 1 : 0;
        if (s_presence.everSeen()) {
            d["r"]   = s_presence.lastRssi();
            d["age"] = s_presence.msSinceSeen(now);
        }
        if (s_presence.hasSmoothed()) d["s"] = serialized(String(s_presence.smoothed(), 1));
        d["pps"] = serialized(String(s_presence.packetsPerSec(), 1));
    }
    int8_t cr;
    if (s_conn != BLE_HS_CONN_HANDLE_NONE && ble_gap_conn_rssi(s_conn, &cr) == 0 && cr != 127) d["cr"] = cr;
    d["wait"] = (armRemainingMs(now) + 999) / 1000;
    d["cd"]   = (cooldownRemainingMs(now) + 999) / 1000;
    d["busy"] = audioBusy() ? 1 : 0;
    if (s_up.active) {
        d["up"]  = s_up.received;
        d["upT"] = s_up.size;
    }
    sendJson(d);
}

static void sendInfo(uint32_t now) {
    JsonDocument d;
    d["t"]    = "i";
    d["v"]    = PROTOCOL_VERSION;
    d["fw"]   = FW_VERSION;
    d["irk"]  = s_matcher.hasIrk();
    d["ce"]   = clipBytes(CLIP_ENTER);
    d["cl"]   = clipBytes(CLIP_LEAVE);
    d["free"] = LittleFS.totalBytes() - LittleFS.usedBytes();
    d["er"]   = s_enrollRes;
    d["upt"]  = now / 1000;
    sendJson(d);
}

static void updateLed(uint32_t now) {
    if (!s_matcher.hasIrk()) {
        // Not set up yet: short yellow blink every 3 s.
        bool on = (now % 3000) < 120;
        on ? ledSet(20, 12, 0) : ledOff();
    } else if (settings.led) {
        s_presence.present() ? ledSet(0, 20, 0) : ledSet(20, 0, 0);
    } else {
        ledOff();
    }
}

void appLoop() {
    uint32_t now = millis();

    Sample s;
    while (xQueueReceive(s_samples, &s, 0) == pdTRUE) {
        Lock l;
        s_presence.addSample(s.rssi, s.ms);
    }
    PresenceEvent e;
    {
        Lock l;
        e = s_presence.update(now);
    }
    if (e != PresenceEvent::None) handleEvent(e, now);

    if (s_matcher.hasIrk() && !s_scan->isScanning()) s_scan->start(0, false, true);
    if (!s_matcher.hasIrk() && s_scan->isScanning()) s_scan->stop();

    static uint32_t lastStatus = 0, lastInfo = 0;
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
        if (s_infoDirty || now - lastInfo >= 5000) {
            s_infoDirty = false;
            lastInfo    = now;
            sendInfo(now);
        }
        if (now - lastStatus >= 500) {
            lastStatus = now;
            sendStatus(now);
        }
    }

    updateLed(now);

    if (s_rebootAt && (int32_t)(now - s_rebootAt) >= 0) {
        NimBLEDevice::deinit(true);
        ESP.restart();
    }
}
