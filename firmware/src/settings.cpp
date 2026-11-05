#include "settings.h"
#include <ArduinoJson.h>
#include <Preferences.h>

Settings settings;
static Preferences prefs;
static const char* NS = "pranker";

template <typename T>
static T clampv(T v, T lo, T hi) { return v < lo ? lo : (v > hi ? hi : v); }

static void clampAll(Settings& s) {
    s.enterRssi   = clampv(s.enterRssi, -110, -20);
    s.exitRssi    = clampv(s.exitRssi, -115, -25);
    if (s.exitRssi > s.enterRssi - 2) s.exitRssi = s.enterRssi - 2;  // keep hysteresis
    s.absenceSec  = clampv(s.absenceSec, 3, 600);
    s.exitHoldSec = clampv(s.exitHoldSec, 0, 120);
    s.smoothing   = clampv(s.smoothing, 0.05f, 1.0f);
    s.cooldownSec = clampv(s.cooldownSec, 0, 3600);
    s.armDelaySec = clampv(s.armDelaySec, 0, 3600);
    s.volume      = clampv(s.volume, 0, 100);
    s.chance      = clampv(s.chance, 0, 100);
    if (s.name.length() == 0) s.name = "Pranker";
    if (s.name.length() > 20) s.name = s.name.substring(0, 20);
}

String settingsToJson() {
    JsonDocument doc;
    doc["armed"]     = settings.armed;
    doc["enter"]     = settings.enterRssi;
    doc["exit"]      = settings.exitRssi;
    doc["absence"]   = settings.absenceSec;
    doc["exitHold"]  = settings.exitHoldSec;
    doc["smooth"]    = serialized(String(settings.smoothing, 2));
    doc["cooldown"]  = settings.cooldownSec;
    doc["armDelay"]  = settings.armDelaySec;
    doc["vol"]       = settings.volume;
    doc["playEnter"] = settings.playEnter;
    doc["playLeave"] = settings.playLeave;
    doc["chance"]    = settings.chance;
    doc["led"]       = settings.led;
    doc["name"]      = settings.name;
    String out;
    serializeJson(doc, out);
    return out;
}

bool settingsApplyJson(const uint8_t* data, size_t len, String& err) {
    JsonDocument doc;
    DeserializationError e = deserializeJson(doc, data, len);
    if (e) {
        err = e.c_str();
        return false;
    }
    Settings s = settings;
    if (doc["armed"].is<bool>())     s.armed       = doc["armed"];
    if (doc["enter"].is<int>())      s.enterRssi   = doc["enter"];
    if (doc["exit"].is<int>())       s.exitRssi    = doc["exit"];
    if (doc["absence"].is<int>())    s.absenceSec  = doc["absence"];
    if (doc["exitHold"].is<int>())   s.exitHoldSec = doc["exitHold"];
    if (doc["smooth"].is<float>())   s.smoothing   = doc["smooth"];
    if (doc["cooldown"].is<int>())   s.cooldownSec = doc["cooldown"];
    if (doc["armDelay"].is<int>())   s.armDelaySec = doc["armDelay"];
    if (doc["vol"].is<int>())        s.volume      = doc["vol"];
    if (doc["playEnter"].is<bool>()) s.playEnter   = doc["playEnter"];
    if (doc["playLeave"].is<bool>()) s.playLeave   = doc["playLeave"];
    if (doc["chance"].is<int>())     s.chance      = doc["chance"];
    if (doc["led"].is<bool>())       s.led         = doc["led"];
    if (doc["name"].is<const char*>()) s.name      = doc["name"].as<const char*>();
    clampAll(s);
    settings = s;
    return true;
}

void settingsLoad() {
    prefs.begin(NS, true);
    String json = prefs.getString("cfg", "");
    prefs.end();
    if (json.length()) {
        String err;
        settingsApplyJson((const uint8_t*)json.c_str(), json.length(), err);
    }
    clampAll(settings);
}

void settingsSave() {
    prefs.begin(NS, false);
    prefs.putString("cfg", settingsToJson());
    prefs.end();
}

bool irkLoad(uint8_t out[16]) {
    prefs.begin(NS, true);
    size_t n = prefs.isKey("irk") ? prefs.getBytes("irk", out, 16) : 0;
    prefs.end();
    return n == 16;
}

void irkSave(const uint8_t irk[16]) {
    prefs.begin(NS, false);
    prefs.putBytes("irk", irk, 16);
    prefs.end();
}

void irkClear() {
    prefs.begin(NS, false);
    prefs.remove("irk");
    prefs.end();
}

void requestEnrollOnNextBoot(bool enable) {
    prefs.begin(NS, false);
    prefs.putBool("enroll", enable);
    prefs.end();
}

bool enrollRequested() {
    prefs.begin(NS, true);
    bool v = prefs.isKey("enroll") && prefs.getBool("enroll", false);
    prefs.end();
    return v;
}

void enrollResultSet(int r) {
    prefs.begin(NS, false);
    prefs.putInt("enrRes", r);
    prefs.end();
}

int enrollResultGet() {
    prefs.begin(NS, true);
    int r = prefs.isKey("enrRes") ? prefs.getInt("enrRes", 0) : 0;
    prefs.end();
    return r;
}
