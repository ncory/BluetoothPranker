#include "targets.h"
#include <ArduinoJson.h>
#include <LittleFS.h>
#include <Preferences.h>
#include "audio.h"

Target   g_targets[MAX_TARGETS];
int      g_targetCount   = 0;
uint32_t g_targetsVersion = 1;

static const char* NS = "pranker";

static void copyName(char* dst, const char* src) {
    strncpy(dst, (src && *src) ? src : "Target", TARGET_NAME_MAX);
    dst[TARGET_NAME_MAX] = 0;
}

void targetsLoad() {
    Preferences p;
    p.begin(NS, false);
    g_targetCount = 0;
    if (p.isKey("targets")) {
        size_t n = p.getBytesLength("targets");
        if (n % sizeof(Target) == 0 && n / sizeof(Target) <= MAX_TARGETS) {
            p.getBytes("targets", g_targets, n);
            g_targetCount = n / sizeof(Target);
        }
    }
    // Migrate the single-target format from firmware 1.0.
    if (p.isKey("irk") && p.getBytesLength("irk") == 16 && g_targetCount == 0) {
        Target& t = g_targets[0];
        t.id      = 1;
        t.enabled = true;
        copyName(t.name, "Target");
        p.getBytes("irk", t.irk, 16);
        g_targetCount = 1;
        p.remove("irk");
        p.putBytes("targets", g_targets, sizeof(Target));
    }
    p.end();
}

void targetsSave() {
    Preferences p;
    p.begin(NS, false);
    if (g_targetCount) p.putBytes("targets", g_targets, g_targetCount * sizeof(Target));
    else p.remove("targets");
    p.end();
    g_targetsVersion++;
}

int targetIndexById(int id) {
    for (int i = 0; i < g_targetCount; i++)
        if (g_targets[i].id == id) return i;
    return -1;
}

int targetAddOrUpdate(const char* name, const uint8_t irk[16]) {
    for (int i = 0; i < g_targetCount; i++) {
        if (memcmp(g_targets[i].irk, irk, 16) == 0) {
            if (name && *name) copyName(g_targets[i].name, name);
            g_targets[i].enabled = true;
            targetsSave();
            return g_targets[i].id;
        }
    }
    if (g_targetCount >= MAX_TARGETS) return -1;
    int maxId = 0;
    for (int i = 0; i < g_targetCount; i++) maxId = max(maxId, (int)g_targets[i].id);
    Target& t = g_targets[g_targetCount++];
    t.id      = maxId >= 255 ? 1 : maxId + 1;
    t.enabled = true;
    copyName(t.name, name);
    memcpy(t.irk, irk, 16);
    targetsSave();
    return t.id;
}

bool targetRemove(int id) {
    int i = targetIndexById(id);
    if (i < 0) return false;
    for (int j = i; j < g_targetCount - 1; j++) g_targets[j] = g_targets[j + 1];
    g_targetCount--;
    LittleFS.remove(clipPathForTarget(id, true));
    LittleFS.remove(clipPathForTarget(id, false));
    targetsSave();
    return true;
}

bool targetRename(int id, const char* name) {
    int i = targetIndexById(id);
    if (i < 0 || !name || !*name) return false;
    copyName(g_targets[i].name, name);
    targetsSave();
    return true;
}

bool targetSetEnabled(int id, bool on) {
    int i = targetIndexById(id);
    if (i < 0) return false;
    g_targets[i].enabled = on;
    targetsSave();
    return true;
}

String targetsJson() {
    JsonDocument d;
    JsonArray    arr = d.to<JsonArray>();
    for (int i = 0; i < g_targetCount; i++) {
        const Target& t = g_targets[i];
        JsonObject    o = arr.add<JsonObject>();
        o["id"] = t.id;
        o["n"]  = t.name;
        o["on"] = t.enabled ? 1 : 0;
        o["ce"] = clipBytesPath(clipPathForTarget(t.id, true));
        o["cl"] = clipBytesPath(clipPathForTarget(t.id, false));
    }
    String s;
    serializeJson(d, s);
    return s;
}
