/* tether_crc32.c — CRC-32 (IEEE) for Tether fakefs. MIT. */
#include "tether_internal.h"

static uint32_t table[256];
static int table_ready = 0;

static void build_table(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        table[i] = c;
    }
    table_ready = 1;
}

uint32_t tether_crc32(uint32_t crc, const void *buf, size_t len)
{
    if (!table_ready)
        build_table();
    const unsigned char *p = (const unsigned char *)buf;
    crc ^= 0xFFFFFFFFu;
    while (len--)
        crc = table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}
