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
#include "targets.h"

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

struct Sample {
    uint8_t  targetId;
    int8_t   rssi;
    uint32_t ms;
};

struct LogEntry {
    uint32_t ms;
    uint8_t  targetId;
    uint8_t  enter;
    uint8_t  played;
};

// Per-target runtime state, index-aligned with g_targets.
struct Tracker {
    RpaMatcher matcher;   // used only on the NimBLE host task
    Presence   presence;  // guarded by s_lock
    uint32_t   lastPlay   = 0;
    bool       everPlayed = false;
};

static const int     LOG_MAX = 20;
static LogEntry      s_log[LOG_MAX];
static int           s_logCount = 0, s_logNext = 0;

static QueueHandle_t     s_samples;
static SemaphoreHandle_t s_lock;  // guards settings, targets, trackers' presence, log
static Tracker           s_trackers[MAX_TARGETS];

static NimBLEServer*         s_server;
static NimBLEScan*           s_scan;
static NimBLECharacteristic *s_chConfig, *s_chCommand, *s_chStatus, *s_chAudio, *s_chLog, *s_chTargets;
static volatile uint16_t     s_conn = BLE_HS_CONN_HANDLE_NONE;

static uint32_t      s_armStart  = 0;
static volatile bool s_infoDirty = true;
static uint32_t      s_rebootAt  = 0;
static int           s_enrollRes = 0;
static volatile bool s_haveTargets = false;  // any enabled target (read by loop)

static struct {
    bool     active = false;
    String   path;
    uint32_t size = 0, crc = 0, received = 0, runningCrc = 0, startMs = 0, chunks = 0, writeUs = 0;
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

// Never hold s_lock while calling into the BLE host.
static void sendJson(JsonDocument& doc) {
    String s;
    serializeJson(doc, s);
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

static uint32_t cooldownRemainingMs(const Tracker& t, uint32_t now) {
    if (!t.everPlayed) return 0;
    uint32_t cd = (uint32_t)settings.cooldownSec * 1000;
    uint32_t el = now - t.lastPlay;
    return el >= cd ? 0 : cd - el;
}

// Re-sync matchers with the target list. Call with s_lock held, on the host
// task (or before scanning starts).
static void rebuildTrackers() {
    bool any = false;
    for (int i = 0; i < g_targetCount; i++) {
        s_trackers[i].matcher.setIrk(g_targets[i].irk);
        any |= g_targets[i].enabled;
    }
    for (int i = g_targetCount; i < MAX_TARGETS; i++) s_trackers[i].matcher.clear();
    s_haveTargets = any;
    s_infoDirty   = true;
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

// Call with s_lock held. Returns the event JSON to notify once the lock is released.
static String handleEvent(int idx, PresenceEvent e, uint32_t now) {
    Tracker&    tr     = s_trackers[idx];
    int         id     = g_targets[idx].id;
    bool        enter  = e == PresenceEvent::Enter;
    bool        played = false;
    const char* why    = nullptr;

    if (!settings.armed) why = "disarmed";
    else if (armRemainingMs(now) > 0) why = "arming";
    else if (enter ? !settings.playEnter : !settings.playLeave) why = "off";
    else if (cooldownRemainingMs(tr, now) > 0) why = "cooldown";
    else if ((int)random(100) >= (enter ? settings.enterChance : settings.leaveChance)) why = "chance";
    else if (audioBusy()) why = "busy";
    else {
        audioPlay(id, enter);
        tr.lastPlay   = now;
        tr.everPlayed = true;
        played        = true;
    }

    s_log[s_logNext] = {now, (uint8_t)id, (uint8_t)enter, (uint8_t)played};
    s_logNext        = (s_logNext + 1) % LOG_MAX;
    if (s_logCount < LOG_MAX) s_logCount++;

    Serial.printf("[event] %s %s played=%d %s\n", g_targets[idx].name, enter ? "ENTER" : "LEAVE", played,
                  why ? why : "");

    JsonDocument d;
    d["t"]      = "e";
    d["id"]     = id;
    d["n"]      = g_targets[idx].name;
    d["ev"]     = enter ? "enter" : "leave";
    d["played"] = played;
    if (why) d["why"] = why;
    String s;
    serializeJson(d, s);
    return s;
}

// ---------------------------------------------------------------------------
// Upload of sound clips (called on the NimBLE host task)
// ---------------------------------------------------------------------------

static void uploadLog(const char* result) {
    uint32_t ms = millis() - s_up.startMs;
    Serial.printf("[upload] %s: %u/%u bytes in %u ms (%u B/s), %u chunks, %u ms writing flash\n", result,
                  (unsigned)s_up.received, (unsigned)s_up.size, (unsigned)ms,
                  (unsigned)(ms ? s_up.received * 1000ULL / ms : 0), (unsigned)s_up.chunks,
                  (unsigned)(s_up.writeUs / 1000));
}

static void uploadAbort(const char* why) {
    if (why && s_up.active) uploadLog(why);
    if (s_up.active) {
        s_up.file.close();
        LittleFS.remove("/upload.tmp");
    }
    s_up.active = false;
    s_infoDirty = true;
    if (why) ack("upload", false, why);
}

// Validates a clip id from the app and checks the target exists.
static bool resolveClip(const char* clipId, int& targetId, bool& enter) {
    if (!clipIdParse(clipId, targetId, enter)) return false;
    if (targetId == 0) return true;
    Lock l;
    return targetIndexById(targetId) >= 0;
}

static void uploadBegin(JsonDocument& doc) {
    if (s_up.active) uploadAbort(nullptr);
    int  targetId;
    bool enter;
    if (!resolveClip(doc["clip"].as<const char*>(), targetId, enter)) return ack("upload", false, "bad clip");
    uint32_t size = doc["size"] | 0u;
    uint32_t crc  = doc["crc"] | 0u;
    if (size < 44 || size > MAX_CLIP_BYTES) return ack("upload", false, "bad size");

    String path      = clipPathForId(targetId, enter);
    size_t freeBytes = LittleFS.totalBytes() - LittleFS.usedBytes() + clipBytesPath(path);
    if (size + 16 * 1024 > freeBytes) return ack("upload", false, "not enough space on the device");

    // Remove the old clip first so its space is available.
    LittleFS.remove(path);
    s_up.file = LittleFS.open("/upload.tmp", "w");
    if (!s_up.file) return ack("upload", false, "fs error");
    s_up.active     = true;
    s_up.path       = path;
    s_up.size       = size;
    s_up.crc        = crc;
    s_up.received   = 0;
    s_up.runningCrc = 0;
    s_up.startMs    = millis();
    s_up.chunks     = 0;
    s_up.writeUs    = 0;
    s_infoDirty     = true;
    ack("upload", true);  // "ready"; the app now streams chunks
}

static void uploadFinish() {
    s_up.file.close();
    s_up.active = false;
    s_infoDirty = true;
    g_targetsVersion++;  // clip sizes are part of the target list

    if (s_up.runningCrc != s_up.crc) {
        uploadLog("crc mismatch");
        LittleFS.remove("/upload.tmp");
        return ack("uploadDone", false, "crc mismatch");
    }
    File    f = LittleFS.open("/upload.tmp", "r");
    WavInfo w;
    bool    ok = f && wavParse(f, w);
    f.close();
    if (!ok) {
        uploadLog("not a 16-bit PCM wav");
        LittleFS.remove("/upload.tmp");
        return ack("uploadDone", false, "not a 16-bit PCM wav");
    }
    LittleFS.rename("/upload.tmp", s_up.path);
    uploadLog("ok");
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
    size_t   len = min<size_t>(n - 4, s_up.size - s_up.received);
    uint32_t t0  = micros();
    if (s_up.file.write(d + 4, len) != len) return uploadAbort("write failed (disk full?)");
    s_up.writeUs += micros() - t0;
    s_up.chunks++;
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
    int         id  = doc["id"] | -1;
    Serial.printf("[cmd] %s\n", cmd);

    if (!strcmp(cmd, "play")) {
        int  targetId = 0;
        bool enter    = true;
        if (!resolveClip(doc["clip"] | "enter", targetId, enter)) return ack(cmd, false, "bad clip");
        audioPlay(targetId, enter);
        ack(cmd, true);
    } else if (!strcmp(cmd, "stop")) {
        audioStop();
        ack(cmd, true);
    } else if (!strcmp(cmd, "enroll")) {
        const char* name = doc["name"] | "Target";
        bool        full;
        {
            Lock l;
            full = g_targetCount >= MAX_TARGETS;
        }
        if (full) return ack(cmd, false, "target list is full, remove one first");
        ack(cmd, true);
        appStartEnrollment(name);
    } else if (!strcmp(cmd, "removeTarget")) {
        bool ok;
        {
            Lock l;
            int  idx = targetIndexById(id);
            ok       = idx >= 0;
            if (ok) {
                // Keep trackers aligned with the shifted target list.
                for (int j = idx; j < g_targetCount - 1; j++) s_trackers[j] = s_trackers[j + 1];
                s_trackers[g_targetCount - 1] = Tracker();
                targetRemove(id);
                rebuildTrackers();
            }
        }
        ack(cmd, ok, ok ? nullptr : "no such target");
    } else if (!strcmp(cmd, "renameTarget")) {
        bool ok;
        {
            Lock l;
            ok = targetRename(id, doc["name"] | "");
            s_infoDirty = true;
        }
        ack(cmd, ok, ok ? nullptr : "no such target");
    } else if (!strcmp(cmd, "enableTarget")) {
        bool ok;
        {
            Lock l;
            ok = targetSetEnabled(id, doc["on"] | true);
            int idx = targetIndexById(id);
            if (ok && !g_targets[idx].enabled) s_trackers[idx].presence.reset();
            rebuildTrackers();
        }
        ack(cmd, ok, ok ? nullptr : "no such target");
    } else if (!strcmp(cmd, "upload")) {
        uploadBegin(doc);
    } else if (!strcmp(cmd, "delete")) {
        int  targetId;
        bool enter;
        if (!resolveClip(doc["clip"].as<const char*>(), targetId, enter)) return ack(cmd, false, "bad clip");
        LittleFS.remove(clipPathForId(targetId, enter));
        s_infoDirty = true;
        g_targetsVersion++;
        ack(cmd, true);
    } else if (!strcmp(cmd, "hide")) {
        // Restart the silent arming period, e.g. right before hiding the device.
        Lock l;
        s_armStart = millis();
        ack(cmd, true);
    } else if (!strcmp(cmd, "clearLog")) {
        {
            Lock l;
            s_logCount = s_logNext = 0;
        }
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
    void onConnect(NimBLEServer* srv, NimBLEConnInfo& ci) override {
        s_conn      = ci.getConnHandle();
        s_infoDirty = true;
        Serial.printf("[ble] app connected %s, interval %.2f ms\n", ci.getAddress().toString().c_str(),
                      ci.getConnInterval() * 1.25f);
        // Ask for long link-layer packets for faster uploads; the phone decides.
        // (Requesting a 15-30 ms interval didn't help: iOS kept 30 ms.)
        srv->setDataLen(ci.getConnHandle(), 251);
    }
    void onConnParamsUpdate(NimBLEConnInfo& ci) override {
        Serial.printf("[ble] conn interval %.2f ms, latency %u, timeout %u ms\n", ci.getConnInterval() * 1.25f,
                      ci.getConnLatency(), ci.getConnTimeout() * 10);
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
        // {"now":<ms>,"ev":[[ms,targetId,enter,played],...]} oldest first. The
        // app turns the ms values into wall-clock times using "now".
        JsonDocument d;
        Lock         l;
        d["now"]        = millis();
        JsonArray arr   = d["ev"].to<JsonArray>();
        int       start = (s_logNext - s_logCount + LOG_MAX) % LOG_MAX;
        for (int i = 0; i < s_logCount; i++) {
            const LogEntry& e = s_log[(start + i) % LOG_MAX];
            JsonArray       a = arr.add<JsonArray>();
            a.add(e.ms);
            a.add(e.targetId);
            a.add(e.enter);
            a.add(e.played);
        }
        String s;
        serializeJson(d, s);
        c->setValue(s);
    }
};

class TargetsCB : public NimBLECharacteristicCallbacks {
    void onRead(NimBLECharacteristic* c, NimBLEConnInfo&) override {
        Lock l;
        c->setValue(targetsJson());
    }
};

class ScanCB : public NimBLEScanCallbacks {
    void onResult(const NimBLEAdvertisedDevice* dev) override {
        const NimBLEAddress& a = dev->getAddress();
        if (!isResolvableAddress(a.getType(), a.getVal())) return;
        // Target list changes also happen on this (host) task, so no lock needed.
        for (int i = 0; i < g_targetCount; i++) {
            if (g_targets[i].enabled && s_trackers[i].matcher.matches(a.getType(), a.getVal())) {
                Sample s{g_targets[i].id, (int8_t)dev->getRSSI(), millis()};
                xQueueSend(s_samples, &s, 0);
                return;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Public
// ---------------------------------------------------------------------------

void appStartEnrollment(const char* targetName) {
    requestEnrollOnNextBoot(targetName && *targetName ? targetName : "Target");
    s_rebootAt = millis() + 600;
}

void appTestPlay(int targetId, bool enter) { audioPlay(targetId, enter); }

void appBegin() {
    s_lock      = xSemaphoreCreateRecursiveMutex();
    s_samples   = xQueueCreate(64, sizeof(Sample));
    s_armStart  = millis();
    s_enrollRes = enrollResultGet();
    rebuildTrackers();
    Serial.printf("[app] %d target(s) enrolled\n", g_targetCount);

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
    s_chTargets = svc->createCharacteristic(CHR_TARGETS, NIMBLE_PROPERTY::READ, 512);
    s_chConfig->setCallbacks(new ConfigCB());
    s_chCommand->setCallbacks(new CommandCB());
    s_chAudio->setCallbacks(new AudioCB());
    s_chLog->setCallbacks(new LogCB());
    s_chTargets->setCallbacks(new TargetsCB());
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

// Per-target presence: {"t":"p","id":1,"st":1,"r":-60,"s":-61.2,"age":120,"pps":1.2,"cd":0}
static void sendTargetStatus(uint32_t now) {
    JsonDocument docs[MAX_TARGETS];
    int          n = 0;
    {
        Lock l;
        for (int i = 0; i < g_targetCount; i++) {
            if (!g_targets[i].enabled) continue;
            const Presence& p = s_trackers[i].presence;
            JsonDocument&   d = docs[n++];
            d["t"]            = "p";
            d["id"]           = g_targets[i].id;
            d["st"]           = p.present() ? 1 : 0;
            if (p.everSeen()) {
                d["r"]   = p.lastRssi();
                d["age"] = p.msSinceSeen(now);
            }
            if (p.hasSmoothed()) d["s"] = serialized(String(p.smoothed(), 1));
            d["pps"] = serialized(String(p.packetsPerSec(), 1));
            d["cd"]  = (cooldownRemainingMs(s_trackers[i], now) + 999) / 1000;
        }
    }
    for (int i = 0; i < n; i++) sendJson(docs[i]);
}

// Global status: {"t":"s","any":1,"cr":-55,"wait":0,"busy":0,"up":..,"upT":..}
static void sendStatus(uint32_t now) {
    JsonDocument d;
    d["t"] = "s";
    {
        Lock l;
        bool any = false;
        for (int i = 0; i < g_targetCount; i++) any |= g_targets[i].enabled && s_trackers[i].presence.present();
        d["any"] = any ? 1 : 0;
    }
    int8_t cr;
    if (s_conn != BLE_HS_CONN_HANDLE_NONE && ble_gap_conn_rssi(s_conn, &cr) == 0 && cr != 127) d["cr"] = cr;
    d["wait"] = (armRemainingMs(now) + 999) / 1000;
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
    {
        Lock l;
        d["nt"] = g_targetCount;
        d["tv"] = g_targetsVersion;
    }
    d["max"]  = MAX_TARGETS;
    d["ce"]   = clipBytesPath(clipPathForId(0, true));
    d["cl"]   = clipBytesPath(clipPathForId(0, false));
    d["free"] = LittleFS.totalBytes() - LittleFS.usedBytes();
    d["er"]   = s_enrollRes;
    d["upt"]  = now / 1000;
    sendJson(d);
}

static void updateLed(uint32_t now) {
    if (!s_haveTargets) {
        // Not set up yet: short yellow blink every 3 s.
        bool on = (now % 3000) < 120;
        on ? ledSet(20, 12, 0) : ledOff();
        return;
    }
    if (!settings.led) return ledOff();
    bool any = false;
    {
        Lock l;
        for (int i = 0; i < g_targetCount; i++) any |= g_targets[i].enabled && s_trackers[i].presence.present();
    }
    any ? ledSet(0, 20, 0) : ledSet(20, 0, 0);
}

void appLoop() {
    uint32_t now = millis();

    // Feed samples and evaluate presence for every target.
    String events[MAX_TARGETS];
    int    nEvents = 0;
    {
        Lock   l;
        Sample s;
        while (xQueueReceive(s_samples, &s, 0) == pdTRUE) {
            int idx = targetIndexById(s.targetId);
            if (idx >= 0) s_trackers[idx].presence.addSample(s.rssi, s.ms);
        }
        for (int i = 0; i < g_targetCount; i++) {
            if (!g_targets[i].enabled) continue;
            PresenceEvent e = s_trackers[i].presence.update(now);
            if (e == PresenceEvent::None) continue;
            events[nEvents++] = handleEvent(i, e, now);
        }
    }
    // Notify outside the lock.
    for (int i = 0; i < nEvents; i++) {
        s_chStatus->setValue(events[i]);
        if (s_conn != BLE_HS_CONN_HANDLE_NONE) s_chStatus->notify();
    }

    // The 90% scan window starves the app connection, so pause it during uploads.
    bool wantScan = s_haveTargets && !s_up.active;
    if (wantScan && !s_scan->isScanning()) s_scan->start(0, false, true);
    if (!wantScan && s_scan->isScanning()) s_scan->stop();

    static uint32_t lastStatus = 0, lastInfo = 0;
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) {
        if (s_infoDirty || now - lastInfo >= 5000) {
            s_infoDirty = false;
            lastInfo    = now;
            sendInfo(now);
        }
        if (now - lastStatus >= 500) {
            lastStatus = now;
            sendTargetStatus(now);  // per-target first; the global status closes the tick
            sendStatus(now);
        }
    }

    updateLed(now);

    if (s_rebootAt && (int32_t)(now - s_rebootAt) >= 0) {
        NimBLEDevice::deinit(true);
        ESP.restart();
    }
}
