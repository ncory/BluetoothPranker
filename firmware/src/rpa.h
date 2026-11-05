// Resolvable Private Address (RPA) matching.
// iPhones rotate their Bluetooth address every ~15 minutes, but every address
// is derived from the phone's Identity Resolving Key (IRK). With the IRK we can
// recognize the phone no matter which address it is currently using.
#pragma once
#include <stdint.h>
#include <stddef.h>

// irkLe: 16-byte IRK in the little-endian order it is exchanged over the air
// (the order NimBLE stores it). addrLe: 6-byte address in NimBLE order (val[0] = LSB).
bool rpaResolves(const uint8_t irkLe[16], const uint8_t addrLe[6]);
bool isResolvableAddress(uint8_t addrType, const uint8_t addrLe[6]);
bool rpaSelfTest();  // Bluetooth Core spec sample data, Vol 3 Part H, D.7

// Fast matcher with a small cache so we only run AES on new addresses.
// Only call from one task (the NimBLE host task).
class RpaMatcher {
  public:
    void setIrk(const uint8_t irkLe[16]);
    void clear();
    bool hasIrk() const { return m_has; }
    bool matches(uint8_t addrType, const uint8_t addrLe[6]);

  private:
    bool    m_has = false;
    uint8_t m_irk[16];
    uint8_t m_hit[6];
    bool    m_hitValid = false;
    static const int MISS = 32;
    uint8_t m_miss[MISS][6];
    int     m_missCount = 0;
    int     m_missNext  = 0;
};
