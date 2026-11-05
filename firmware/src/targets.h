// The list of phones the device recognizes. Each target is an iPhone that was
// paired once in enrollment mode; we keep its name and Identity Resolving Key.
#pragma once
#include <Arduino.h>

static const int MAX_TARGETS   = 8;
static const int TARGET_NAME_MAX = 16;

struct Target {
    uint8_t id;                       // stable id (1..255), used in clip names
    bool    enabled;
    char    name[TARGET_NAME_MAX + 1];
    uint8_t irk[16];
};

extern Target   g_targets[MAX_TARGETS];
extern int      g_targetCount;
extern uint32_t g_targetsVersion;  // bumps on every change, so the app knows to re-read

void targetsLoad();
void targetsSave();
int  targetIndexById(int id);
// Adds a target, or if this phone (same IRK) is already known, renames and
// re-enables it. Returns the target's id, or -1 if the list is full.
int  targetAddOrUpdate(const char* name, const uint8_t irk[16]);
bool targetRemove(int id);
bool targetRename(int id, const char* name);
bool targetSetEnabled(int id, bool on);
String targetsJson();  // [{"id":1,"n":"Alex","on":1,"ce":0,"cl":0}, ...]
