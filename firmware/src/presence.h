// Turns a stream of RSSI samples from the target phone into enter/leave events.
//
//   AWAY --(smoothed RSSI >= enter threshold)--> PRESENT
//   PRESENT --(RSSI <= exit threshold for exitHold seconds)--> AWAY
//   PRESENT --(no packets for absence seconds)--> AWAY
//
// The gap between the enter and exit thresholds (hysteresis) stops it from
// flapping when someone stands near the edge.
#pragma once
#include <stdint.h>

enum class PresenceEvent : uint8_t { None, Enter, Leave };

class Presence {
  public:
    void          addSample(int8_t rssi, uint32_t nowMs);
    PresenceEvent update(uint32_t nowMs);
    void          reset();

    bool     present() const { return m_present; }
    bool     everSeen() const { return m_everSeen; }
    int8_t   lastRssi() const { return m_lastRssi; }
    float    smoothed() const { return m_smoothed; }
    bool     hasSmoothed() const { return m_hasSmoothed; }
    uint32_t msSinceSeen(uint32_t nowMs) const { return m_everSeen ? nowMs - m_lastSeen : UINT32_MAX; }
    float    packetsPerSec() const { return m_pps; }

  private:
    bool     m_present     = false;
    bool     m_everSeen    = false;
    bool     m_hasSmoothed = false;
    float    m_smoothed    = -127;
    int8_t   m_lastRssi    = -127;
    uint32_t m_lastSeen    = 0;
    uint32_t m_weakSince   = 0;
    bool     m_weak        = false;
    uint32_t m_winStart    = 0;
    uint32_t m_winCount    = 0;
    float    m_pps         = 0;
};
