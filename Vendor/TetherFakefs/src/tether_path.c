/* tether_path.c — lexical path normalization for Tether fakefs. MIT. */
#include "tether_internal.h"

#include <errno.h>
#include <string.h>

/*
 * Lexically normalize `in` into `out` as a store-relative path:
 *   - leading '/' and "./" stripped
 *   - repeated '/' collapsed
 *   - "." components dropped
 *   - ".." pops the previous component; ".." past the root is clamped
 *     (tar members like "../x" become "x", matching how an extractor
 *     confined to a root directory behaves)
 *   - trailing '/' dropped
 * Result may be the empty string (the root itself).
 */
int tether_normalize_path(const char *in, char *out, size_t outlen)
{
    if (!in || !out || outlen == 0)
        return -EINVAL;

    size_t olen = 0;         /* bytes written to out (no NUL yet) */
    const char *p = in;

    while (*p == '/')
        p++;

    while (*p) {
        /* find next component [p, q) */
        const char *q = p;
        while (*q && *q != '/')
            q++;
        size_t clen = (size_t)(q - p);

        if (clen == 1 && p[0] == '.') {
            /* skip "." */
        } else if (clen == 2 && p[0] == '.' && p[1] == '.') {
            /* pop last component, clamp at root */
            while (olen > 0 && out[olen - 1] != '/')
                olen--;
            if (olen > 0)
                olen--; /* drop the '/' too */
        } else if (clen > 0) {
            size_t need = olen + (olen ? 1 : 0) + clen;
            if (need + 1 > outlen)
                return -ENAMETOOLONG;
            if (olen)
                out[olen++] = '/';
            memcpy(out + olen, p, clen);
            olen += clen;
        }

        p = q;
        while (*p == '/')
            p++;
    }

    out[olen] = '\0';
    return 0;
}
