#include "enroll.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>

#include "led.h"
#include "protocol.h"
#include "rpa.h"
#include "settings.h"
#include "targets.h"

static const uint32_t ENROLL_TIMEOUT_MS = 3 * 60 * 1000;

static volatile bool     s_done   = false;
static volatile bool     s_failed = false;
static volatile uint16_t s_conn   = BLE_HS_CONN_HANDLE_NONE;
static uint8_t           s_irk[16];

// Standard boot keyboard report map (report ID 1). iOS only offers to pair
// with BLE devices from Settings if they look like a keyboard/mouse/etc.
static uint8_t s_reportMap[] = {
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x06,
    0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0,
};

static void printHex(const char* label, const uint8_t* b, int n, bool reverse) {
    Serial.print(label);
    for (int i = 0; i < n; i++) Serial.printf("%02x", b[reverse ? n - 1 - i : i]);
    Serial.println();
}

class EnrollServerCB : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer*, NimBLEConnInfo& ci) override {
        s_conn = ci.getConnHandle();
        Serial.printf("[enroll] connected: %s, requesting pairing\n", ci.getAddress().toString().c_str());
        NimBLEDevice::startSecurity(ci.getConnHandle());
    }

    void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int reason) override {
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        Serial.printf("[enroll] disconnected (%d)\n", reason);
    }

    void onAuthenticationComplete(NimBLEConnInfo& ci) override {
        if (!ci.isEncrypted()) {
            Serial.println("[enroll] pairing failed");
            return;  // let the user retry within the timeout
        }

        NimBLEAddress           id = ci.getIdAddress();
        struct ble_store_key_sec key;
        memset(&key, 0, sizeof key);
        key.peer_addr = *id.getBase();
        struct ble_store_value_sec val;
        memset(&val, 0, sizeof val);

        if (ble_store_read_peer_sec(&key, &val) != 0 || !val.irk_present) {
            Serial.println("[enroll] paired, but the phone did not share an IRK");
            s_failed = true;
            return;
        }

        // Sanity-check the key against the address the phone used for this
        // connection. If the byte order were reversed, fix it up.
        NimBLEAddress ota = ci.getAddress();
        memcpy(s_irk, val.irk, 16);
        if (isResolvableAddress(ota.getType(), ota.getVal()) && !rpaResolves(s_irk, ota.getVal())) {
            uint8_t rev[16];
            for (int i = 0; i < 16; i++) rev[i] = val.irk[15 - i];
            if (rpaResolves(rev, ota.getVal())) memcpy(s_irk, rev, 16);
            else Serial.println("[enroll] warning: IRK does not resolve connection address");
        }
        printHex("[enroll] got IRK (LE): ", s_irk, 16, false);
        s_done = true;
    }
};

void enrollRun(const String& targetName) {
    Serial.printf("[enroll] === ENROLLMENT MODE for '%s' ===\n", targetName.c_str());
    Serial.println("[enroll] On the target iPhone: Settings > Bluetooth, tap the device under 'Other Devices', then Pair.");

    String name = settings.name;
    if (name.length() > 16) name = name.substring(0, 16);
    NimBLEDevice::init(name.c_str());

    // Use a throw-away random address, so after we reboot into normal mode the
    // iPhone never recognizes us as its paired "keyboard" and won't reconnect.
    ble_addr_t addr;
    ble_hs_id_gen_rnd(0, &addr);
    NimBLEDevice::setOwnAddr(addr.val);
    NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM);

    NimBLEDevice::deleteAllBonds();
    NimBLEDevice::setSecurityAuth(/*bonding=*/true, /*mitm=*/false, /*sc=*/true);
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
    NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
    NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);

    NimBLEServer* server = NimBLEDevice::createServer();
    server->setCallbacks(new EnrollServerCB());

    NimBLEHIDDevice* hid = new NimBLEHIDDevice(server);
    hid->setManufacturer("Espressif");
    hid->setPnp(0x02, 0xe502, 0xa111, 0x0210);
    hid->setHidInfo(0x00, 0x01);
    hid->setReportMap(s_reportMap, sizeof(s_reportMap));
    hid->getInputReport(1);
    hid->setBatteryLevel(100);
    server->start();

    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    adv->setAppearance(0x03C1);  // HID keyboard
    adv->addServiceUUID(hid->getHidService()->getUUID());
    adv->setName(name.c_str());
    adv->start();

    uint32_t start   = millis();
    int      result  = ENROLL_TIMEOUT;
    bool     wasDown = digitalRead(PIN_BUTTON) == LOW;
    for (;;) {
        uint32_t now = millis();
        (now / 400) % 2 ? ledSet(0, 0, 30) : ledSet(0, 0, 4);  // pulsing blue

        if (s_done) {
            result = targetAddOrUpdate(targetName.c_str(), s_irk) > 0 ? ENROLL_OK : ENROLL_FULL;
            break;
        }
        if (s_failed) {
            result = ENROLL_FAILED;
            break;
        }
        if (now - start > ENROLL_TIMEOUT_MS) break;

        bool down = digitalRead(PIN_BUTTON) == LOW;
        if (down && !wasDown) {
            result = ENROLL_CANCELLED;
            break;
        }
        wasDown = down;
        delay(20);
    }

    Serial.printf("[enroll] finished, result=%d\n", result);
    enrollResultSet(result);
    if (s_conn != BLE_HS_CONN_HANDLE_NONE) server->disconnect(s_conn);
    delay(300);
    NimBLEDevice::deleteAllBonds();

    if (result == ENROLL_OK) ledSet(0, 30, 0);
    else ledSet(30, 0, 0);
    delay(1500);
    ledOff();
    NimBLEDevice::deinit(true);
    ESP.restart();
    for (;;) {}
}
