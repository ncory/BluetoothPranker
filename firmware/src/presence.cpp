#include "presence.h"
#include "settings.h"

void Presence::reset() {
    m_present     = false;
    m_hasSmoothed = false;
    m_weak        = false;
}

void Presence::addSample(int8_t rssi, uint32_t now) {
    m_lastRssi = rssi;
    m_lastSeen = now;
    m_everSeen = true;
    m_winCount++;
    if (!m_hasSmoothed) {
        m_smoothed    = rssi;
        m_hasSmoothed = true;
    } else {
        m_smoothed += settings.smoothing * (rssi - m_smoothed);
    }
}

PresenceEvent Presence::update(uint32_t now) {
    if (now - m_winStart >= 5000) {
        m_pps      = m_winCount * 1000.0f / (now - m_winStart);
        m_winCount = 0;
        m_winStart = now;
    }

    bool fresh = m_everSeen && (now - m_lastSeen) < (uint32_t)settings.absenceSec * 1000;
    if (!fresh) m_hasSmoothed = false;  // start smoothing from scratch next time we see it

    if (!m_present) {
        if (fresh && m_smoothed >= settings.enterRssi) {
            m_present = true;
            m_weak    = false;
            return PresenceEvent::Enter;
        }
        return PresenceEvent::None;
    }

    if (!fresh) {
        m_present = false;
        return PresenceEvent::Leave;
    }
    if (m_smoothed <= settings.exitRssi) {
        if (!m_weak) {
            m_weak      = true;
            m_weakSince = now;
        } else if (now - m_weakSince >= (uint32_t)settings.exitHoldSec * 1000) {
            m_present = false;
            m_weak    = false;
            return PresenceEvent::Leave;
        }
    } else {
        m_weak = false;
    }
    return PresenceEvent::None;
}
