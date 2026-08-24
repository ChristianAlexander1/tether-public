#!/usr/bin/env bash
set -euo pipefail

# Host-only smoke binary for CI on macOS/Linux. This intentionally avoids iOS SDKs
# and network access. It builds a tiny rg-compatible substring scanner sufficient
# for tests/host_smoke.sh; iOS production archives are produced by build-ios.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${ROOT_DIR}/.host/bin"
mkdir -p "${OUT_DIR}" "${ROOT_DIR}/.host/src"

CC="${CC:-cc}"
cat > "${ROOT_DIR}/.host/src/tether_host_rg.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static const char *needle;
static int matches = 0;

static void scan_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    long no = 0;
    while ((len = getline(&line, &cap, f)) != -1) {
        (void)len;
        no++;
        if (strstr(line, needle)) {
            printf("%s:%ld:%s", path, no, line);
            if (line[0] && line[strlen(line)-1] != '\n') putchar('\n');
            matches++;
        }
    }
    free(line);
    fclose(f);
}

static void walk(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return;
    if (S_ISREG(st.st_mode)) { scan_file(path); return; }
    if (!S_ISDIR(st.st_mode)) return;
    DIR *d = opendir(path);
    if (!d) return;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        char child[PATH_MAX];
        snprintf(child, sizeof(child), "%s/%s", path, ent->d_name);
        walk(child);
    }
    closedir(d);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: rg PATTERN [PATH]\n");
        return 2;
    }
    needle = argv[1];
    if (argc == 2) walk(".");
    else for (int i = 2; i < argc; i++) walk(argv[i]);
    return matches ? 0 : 1;
}
C

"${CC}" -std=c99 -Wall -Wextra -O2 -D_GNU_SOURCE "${ROOT_DIR}/.host/src/tether_host_rg.c" -o "${OUT_DIR}/rg"
chmod +x "${OUT_DIR}/rg"
printf 'Built host rg smoke binary: %s\n' "${OUT_DIR}/rg"
