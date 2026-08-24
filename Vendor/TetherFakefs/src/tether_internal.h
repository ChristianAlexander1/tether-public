/* tether_internal.h — shared internals for the Tether fakefs library. MIT. */
#ifndef TETHER_INTERNAL_H
#define TETHER_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

/* ---------------- on-disk format (little-endian) ------------------- */

#define TETHER_IDX_MAGIC   "TFAKEFS1"   /* 8 bytes, no NUL             */
#define TETHER_IDX_VERSION 1u
#define TETHER_IDX_NAME    "tetherfs.idx"
#define TETHER_DATA_DIR    "data"
#define TETHER_NO_STR      0xFFFFFFFFu  /* "no string" sentinel        */
#define TETHER_NO_INODE    0xFFFFFFFFu  /* "no data file" sentinel     */

/* Fixed 40-byte header at offset 0 of tetherfs.idx. */
typedef struct tether_idx_header {
    char     magic[8];       /* "TFAKEFS1"                             */
    uint32_t version;        /* 1                                      */
    uint32_t entry_count;    /* number of entry records                */
    uint64_t strtab_off;     /* byte offset of string table            */
    uint64_t strtab_size;    /* string table size in bytes             */
    uint64_t inode_count;    /* number of data files under data/       */
} tether_idx_header;

/* Fixed 56-byte entry record; entry_count of these follow the header,
 * sorted ascending by path (bytewise strcmp). */
typedef struct tether_idx_entry {
    uint32_t path_off;       /* strtab offset of NUL-terminated path   */
    uint32_t link_off;       /* symlink target, or TETHER_NO_STR       */
    uint32_t mode;           /* full st_mode                           */
    uint32_t uid;
    uint32_t gid;
    uint32_t inode;          /* data/%08x, or TETHER_NO_INODE          */
    uint64_t size;           /* regular-file content bytes, else 0     */
    uint64_t rdev;           /* device number for c/b nodes, else 0    */
    int64_t  mtime;          /* seconds since epoch                    */
    uint32_t crc32;          /* CRC-32 (IEEE) of content, else 0       */
    uint32_t reserved;       /* must be 0                              */
} tether_idx_entry;

_Static_assert(sizeof(tether_idx_header) == 40, "header must be 40 bytes");
_Static_assert(sizeof(tether_idx_entry) == 56, "entry must be 56 bytes");

/* ---------------- helpers ------------------------------------------ */

/* CRC-32 (IEEE 802.3, poly 0xEDB88320), seed with 0. */
uint32_t tether_crc32(uint32_t crc, const void *buf, size_t len);

/*
 * Normalize a tar member path or lookup path in place semantics:
 * strips leading "./" and "/", collapses duplicate '/', resolves "." and
 * ".." lexically, drops trailing '/'. Writes the result (possibly "")
 * into out. Returns 0 or -EINVAL / -ENAMETOOLONG.
 */
int tether_normalize_path(const char *in, char *out, size_t outlen);

#endif /* TETHER_INTERNAL_H */
