#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_DIR="${ROOT_DIR}/.host"
BIN_DIR="${HOST_DIR}/bin"
SRC_DIR="${HOST_DIR}/src"
FIXTURE_DIR="${HOST_DIR}/fixture"
mkdir -p "${BIN_DIR}" "${SRC_DIR}" "${FIXTURE_DIR}/nested"

CC="${CC:-cc}"

printf '==> Building host smoke binaries\n'
"${ROOT_DIR}/ripgrep/host-test.sh"

cat > "${SRC_DIR}/tether_host_fd.c" <<'C'
#include <stdio.h>
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
static int found = 0;

static void walk(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return;
    if (S_ISREG(st.st_mode)) {
        const char *base = strrchr(path, '/');
        base = base ? base + 1 : path;
        if (strstr(base, needle)) {
            puts(path);
            found++;
        }
        return;
    }
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
        fprintf(stderr, "usage: fd PATTERN [PATH]\n");
        return 2;
    }
    needle = argv[1];
    if (argc == 2) walk(".");
    else for (int i = 2; i < argc; i++) walk(argv[i]);
    return found ? 0 : 1;
}
C
"${CC}" -std=c99 -Wall -Wextra -O2 -D_GNU_SOURCE "${SRC_DIR}/tether_host_fd.c" -o "${BIN_DIR}/fd"
chmod +x "${BIN_DIR}/fd"
printf 'Built host fd smoke binary: %s\n' "${BIN_DIR}/fd"

printf '==> Preparing fixtures\n'
rm -rf "${FIXTURE_DIR}"
mkdir -p "${FIXTURE_DIR}/nested"
printf 'well hello from Tether\n' > "${FIXTURE_DIR}/nested/test_hello.txt"
printf 'another file\n' > "${FIXTURE_DIR}/notes.md"

printf '==> rg hello should match\n'
RG_OUT="$(cd "${FIXTURE_DIR}" && "${BIN_DIR}/rg" hello)"
printf '%s\n' "${RG_OUT}"
echo "${RG_OUT}" | grep -q 'hello'

printf '==> fd test should find file\n'
FD_OUT="$(cd "${FIXTURE_DIR}" && "${BIN_DIR}/fd" test)"
printf '%s\n' "${FD_OUT}"
echo "${FD_OUT}" | grep -q 'test_hello.txt'

printf 'host_smoke.sh: PASS\n'
