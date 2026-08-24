/*
 * tether_wasi_abi.h — constants and struct layouts of wasi_snapshot_preview1
 *
 * Copyright (c) 2026 Tether
 * SPDX-License-Identifier: MIT
 *
 * Hand-written subset of the WASI preview1 ABI. Only what the runner actually
 * implements appears here; the layouts and values match the witx-generated
 * wasi/api.h shipped with wasi-libc, and the static assertions at the bottom
 * of tether_wasi.c pin the struct sizes so a mismatch fails the build rather
 * than corrupting guest memory.
 */

#ifndef TETHER_WASI_ABI_H
#define TETHER_WASI_ABI_H

#include <stdint.h>

typedef uint32_t tw_size_t;
typedef uint32_t tw_fd_t;
typedef uint16_t tw_errno_t;
typedef uint64_t tw_rights_t;
typedef uint64_t tw_filesize_t;
typedef uint64_t tw_timestamp_t;
typedef int64_t  tw_filedelta_t;
typedef uint8_t  tw_filetype_t;
typedef uint16_t tw_oflags_t;
typedef uint16_t tw_fdflags_t;
typedef uint32_t tw_lookupflags_t;
typedef uint8_t  tw_whence_t;
typedef uint64_t tw_dircookie_t;
typedef uint64_t tw_device_t;
typedef uint64_t tw_inode_t;
typedef uint64_t tw_linkcount_t;
typedef uint32_t tw_clockid_t;

/* errno ------------------------------------------------------------------ */
#define TW_ERRNO_SUCCESS        UINT16_C(0)
#define TW_ERRNO_2BIG           UINT16_C(1)
#define TW_ERRNO_ACCES          UINT16_C(2)
#define TW_ERRNO_AGAIN          UINT16_C(6)
#define TW_ERRNO_BADF           UINT16_C(8)
#define TW_ERRNO_BUSY           UINT16_C(10)
#define TW_ERRNO_DEADLK         UINT16_C(16)
#define TW_ERRNO_EXIST          UINT16_C(20)
#define TW_ERRNO_FAULT          UINT16_C(21)
#define TW_ERRNO_FBIG           UINT16_C(22)
#define TW_ERRNO_INTR           UINT16_C(27)
#define TW_ERRNO_INVAL          UINT16_C(28)
#define TW_ERRNO_IO             UINT16_C(29)
#define TW_ERRNO_ISDIR          UINT16_C(31)
#define TW_ERRNO_LOOP           UINT16_C(32)
#define TW_ERRNO_MFILE          UINT16_C(33)
#define TW_ERRNO_MLINK          UINT16_C(34)
#define TW_ERRNO_NAMETOOLONG    UINT16_C(37)
#define TW_ERRNO_NFILE          UINT16_C(38)
#define TW_ERRNO_NODEV          UINT16_C(42)
#define TW_ERRNO_NOENT          UINT16_C(44)
#define TW_ERRNO_NOEXEC         UINT16_C(45)
#define TW_ERRNO_NOMEM          UINT16_C(48)
#define TW_ERRNO_NOSPC          UINT16_C(51)
#define TW_ERRNO_NOSYS          UINT16_C(52)
#define TW_ERRNO_NOTDIR         UINT16_C(54)
#define TW_ERRNO_NOTEMPTY       UINT16_C(55)
#define TW_ERRNO_NOTSUP         UINT16_C(58)
#define TW_ERRNO_NOTTY          UINT16_C(59)
#define TW_ERRNO_NXIO           UINT16_C(60)
#define TW_ERRNO_OVERFLOW       UINT16_C(61)
#define TW_ERRNO_PERM           UINT16_C(63)
#define TW_ERRNO_PIPE           UINT16_C(64)
#define TW_ERRNO_RANGE          UINT16_C(68)
#define TW_ERRNO_ROFS           UINT16_C(69)
#define TW_ERRNO_SPIPE          UINT16_C(70)
#define TW_ERRNO_TXTBSY         UINT16_C(74)
#define TW_ERRNO_XDEV           UINT16_C(75)
#define TW_ERRNO_NOTCAPABLE     UINT16_C(76)

/* filetype --------------------------------------------------------------- */
#define TW_FILETYPE_UNKNOWN             UINT8_C(0)
#define TW_FILETYPE_BLOCK_DEVICE        UINT8_C(1)
#define TW_FILETYPE_CHARACTER_DEVICE    UINT8_C(2)
#define TW_FILETYPE_DIRECTORY           UINT8_C(3)
#define TW_FILETYPE_REGULAR_FILE        UINT8_C(4)
#define TW_FILETYPE_SOCKET_DGRAM        UINT8_C(5)
#define TW_FILETYPE_SOCKET_STREAM       UINT8_C(6)
#define TW_FILETYPE_SYMBOLIC_LINK       UINT8_C(7)

/* open / fd flags -------------------------------------------------------- */
#define TW_OFLAGS_CREAT         UINT16_C(1)
#define TW_OFLAGS_DIRECTORY     UINT16_C(2)
#define TW_OFLAGS_EXCL          UINT16_C(4)
#define TW_OFLAGS_TRUNC         UINT16_C(8)

#define TW_FDFLAGS_APPEND       UINT16_C(1)
#define TW_FDFLAGS_DSYNC        UINT16_C(2)
#define TW_FDFLAGS_NONBLOCK     UINT16_C(4)
#define TW_FDFLAGS_RSYNC        UINT16_C(8)
#define TW_FDFLAGS_SYNC         UINT16_C(16)

#define TW_LOOKUPFLAGS_SYMLINK_FOLLOW   UINT32_C(1)

/* rights (only the ones the runner reasons about) ------------------------ */
#define TW_RIGHTS_FD_DATASYNC           (UINT64_C(1) << 0)
#define TW_RIGHTS_FD_READ               (UINT64_C(1) << 1)
#define TW_RIGHTS_FD_SEEK               (UINT64_C(1) << 2)
#define TW_RIGHTS_FD_SYNC               (UINT64_C(1) << 4)
#define TW_RIGHTS_FD_TELL               (UINT64_C(1) << 5)
#define TW_RIGHTS_FD_WRITE              (UINT64_C(1) << 6)
#define TW_RIGHTS_FD_READDIR            (UINT64_C(1) << 14)
#define TW_RIGHTS_PATH_OPEN             (UINT64_C(1) << 13)

/* whence ----------------------------------------------------------------- */
#define TW_WHENCE_SET   UINT8_C(0)
#define TW_WHENCE_CUR   UINT8_C(1)
#define TW_WHENCE_END   UINT8_C(2)

/* clocks ----------------------------------------------------------------- */
#define TW_CLOCKID_REALTIME             UINT32_C(0)
#define TW_CLOCKID_MONOTONIC            UINT32_C(1)
#define TW_CLOCKID_PROCESS_CPUTIME_ID   UINT32_C(2)
#define TW_CLOCKID_THREAD_CPUTIME_ID    UINT32_C(3)

/* preopen ---------------------------------------------------------------- */
#define TW_PREOPENTYPE_DIR      UINT8_C(0)

/* poll_oneoff ------------------------------------------------------------ */
#define TW_EVENTTYPE_CLOCK      UINT8_C(0)
#define TW_EVENTTYPE_FD_READ    UINT8_C(1)
#define TW_EVENTTYPE_FD_WRITE   UINT8_C(2)
#define TW_SUBCLOCKFLAGS_ABSTIME  UINT16_C(1)

/*
 * Guest-memory struct layouts. These describe memory inside the wasm linear
 * address space, so every field is at its witx-specified offset and is read
 * and written through the m3ApiReadMem/WriteMem accessors rather than by
 * direct struct assignment.
 */

/* iovec / ciovec: 8 bytes, 4-byte aligned */
#define TW_IOVEC_SIZE           8u
#define TW_IOVEC_OFF_BUF        0u
#define TW_IOVEC_OFF_BUF_LEN    4u

/* fdstat: 24 bytes, 8-byte aligned */
#define TW_FDSTAT_SIZE                      24u
#define TW_FDSTAT_OFF_FILETYPE              0u
#define TW_FDSTAT_OFF_FLAGS                 2u
#define TW_FDSTAT_OFF_RIGHTS_BASE           8u
#define TW_FDSTAT_OFF_RIGHTS_INHERITING     16u

/* filestat: 64 bytes, 8-byte aligned */
#define TW_FILESTAT_SIZE            64u
#define TW_FILESTAT_OFF_DEV         0u
#define TW_FILESTAT_OFF_INO         8u
#define TW_FILESTAT_OFF_FILETYPE    16u
#define TW_FILESTAT_OFF_NLINK       24u
#define TW_FILESTAT_OFF_SIZE        32u
#define TW_FILESTAT_OFF_ATIM        40u
#define TW_FILESTAT_OFF_MTIM        48u
#define TW_FILESTAT_OFF_CTIM        56u

/* prestat: 8 bytes, 4-byte aligned */
#define TW_PRESTAT_SIZE             8u
#define TW_PRESTAT_OFF_TYPE         0u
#define TW_PRESTAT_OFF_NAME_LEN     4u

/* dirent: 24 bytes, 8-byte aligned */
#define TW_DIRENT_SIZE              24u
#define TW_DIRENT_OFF_NEXT          0u
#define TW_DIRENT_OFF_INO           8u
#define TW_DIRENT_OFF_NAMLEN        16u
#define TW_DIRENT_OFF_TYPE          20u

/* subscription: 48 bytes / event: 32 bytes (poll_oneoff) */
#define TW_SUBSCRIPTION_SIZE                48u
#define TW_SUB_OFF_USERDATA                 0u
#define TW_SUB_OFF_TAG                      8u
#define TW_SUB_CLOCK_OFF_ID                 16u
#define TW_SUB_CLOCK_OFF_TIMEOUT            24u
#define TW_SUB_CLOCK_OFF_PRECISION          32u
#define TW_SUB_CLOCK_OFF_FLAGS              40u
#define TW_SUB_FDRW_OFF_FD                  16u

#define TW_EVENT_SIZE                       32u
#define TW_EVENT_OFF_USERDATA               0u
#define TW_EVENT_OFF_ERROR                  8u
#define TW_EVENT_OFF_TYPE                   10u
#define TW_EVENT_OFF_FD_NBYTES              16u
#define TW_EVENT_OFF_FD_FLAGS               24u

#endif /* TETHER_WASI_ABI_H */
