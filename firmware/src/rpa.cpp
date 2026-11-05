#include "rpa.h"
#include <string.h>
#include "mbedtls/aes.h"

bool isResolvableAddress(uint8_t addrType, const uint8_t a[6]) {
    // Random address (type 1) with the two most significant bits == 0b01.
    return (addrType & 1) && ((a[5] & 0xC0) == 0x40);
}

bool rpaResolves(const uint8_t irkLe[16], const uint8_t a[6]) {
    // ah(k, r) = e(k, 0^104 || prand) mod 2^24   (Core spec Vol 3 Part H 2.2.2)
    uint8_t key[16], in[16] = {0}, out[16];
    for (int i = 0; i < 16; i++) key[i] = irkLe[15 - i];  // AES wants MSB first
    in[13] = a[5];
    in[14] = a[4];
    in[15] = a[3];

    mbedtls_aes_context ctx;
    mbedtls_aes_init(&ctx);
    mbedtls_aes_setkey_enc(&ctx, key, 128);
    mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT, in, out);
    mbedtls_aes_free(&ctx);

    return a[0] == out[15] && a[1] == out[14] && a[2] == out[13];
}

bool rpaSelfTest() {
    static const uint8_t irkBe[16] = {0xec, 0x02, 0x34, 0xa3, 0x57, 0xc8, 0xad, 0x05,
                                      0x34, 0x10, 0x10, 0xa6, 0x0a, 0x39, 0x7d, 0x9b};
    uint8_t irkLe[16];
    for (int i = 0; i < 16; i++) irkLe[i] = irkBe[15 - i];
    const uint8_t good[6] = {0xaa, 0xfb, 0x0d, 0x94, 0x81, 0x70};  // 70:81:94:0D:FB:AA
    const uint8_t bad[6]  = {0xab, 0xfb, 0x0d, 0x94, 0x81, 0x70};
    return rpaResolves(irkLe, good) && !rpaResolves(irkLe, bad);
}

void RpaMatcher::setIrk(const uint8_t irkLe[16]) {
    memcpy(m_irk, irkLe, 16);
    m_has       = true;
    m_hitValid  = false;
    m_missCount = 0;
    m_missNext  = 0;
}

void RpaMatcher::clear() {
    m_has       = false;
    m_hitValid  = false;
    m_missCount = 0;
}

bool RpaMatcher::matches(uint8_t addrType, const uint8_t a[6]) {
    if (!m_has || !isResolvableAddress(addrType, a)) return false;
    if (m_hitValid && memcmp(m_hit, a, 6) == 0) return true;
    for (int i = 0; i < m_missCount; i++)
        if (memcmp(m_miss[i], a, 6) == 0) return false;

    if (rpaResolves(m_irk, a)) {
        memcpy(m_hit, a, 6);
        m_hitValid = true;
        return true;
    }
    memcpy(m_miss[m_missNext], a, 6);
    m_missNext = (m_missNext + 1) % MISS;
    if (m_missCount < MISS) m_missCount++;
    return false;
}
