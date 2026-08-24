#!/usr/bin/env bash
#
# run-all.sh — Tether Linux/Blink test harness runner
#
# Runs every fixture in fixtures/ against a real Alpine minirootfs under the
# Blink x86-64 emulator. Each fixture is a self-contained /bin/sh script that
# declares its expectations in header comments:
#
#   # FIXTURE:        unique id/name
#   # CATEGORY:       group label
#   # EXPECT_CONTAINS: substring that must appear in combined stdout+stderr
#   # EXPECT_EXIT:    expected guest exit code (default 0)
#   # TAGS:           space-separated: "offline" or "network"
#
# Usage:
#   ROOTFS=/path/to/alpine-rootfs ./run-all.sh
#   ROOTFS=... BLINK_BIN=/path/to/blink ./run-all.sh
#   NETWORK=1 ./run-all.sh        # also run network-tagged fixtures
#   ./run-all.sh --verbose        # show fixture output as it runs
#   ./run-all.sh --list           # list discovered fixtures and exit
#
# Exit status: 0 if all RUN fixtures passed, 1 if any failed.
#
set -u

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"
GAP_LOG="$SCRIPT_DIR/SYSCALL-GAP-LOG.md"

# BLINK_BIN may be overridden; otherwise look for `blink` on PATH.
BLINK_BIN="${BLINK_BIN:-blink}"
NETWORK="${NETWORK:-0}"
VERBOSE=0
LIST_ONLY=0
TIMEOUT_SECS="${TIMEOUT_SECS:-30}"

for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    --list)       LIST_ONLY=1 ;;
    --network)    NETWORK=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
if [ -t 1 ]; then C_OK="$GREEN"; C_FAIL="$RED"; C_SKIP="$YELLOW"; C_BOLD="$BOLD"; C_RST="$RESET"
else C_OK=""; C_FAIL=""; C_SKIP=""; C_BOLD=""; C_RST=""; fi

log() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 2; }

[ -d "$FIXTURE_DIR" ] || die "fixture directory not found: $FIXTURE_DIR"

# Resolve blink: explicit path, PATH, or a build-tree binary next to us.
if ! command -v "$BLINK_BIN" >/dev/null 2>&1; then
  if [ -x "$SCRIPT_DIR/blink/blink" ]; then
    BLINK_BIN="$SCRIPT_DIR/blink/blink"
  elif [ -x "$SCRIPT_DIR/blink/o/blink/blink" ]; then
    BLINK_BIN="$SCRIPT_DIR/blink/o/blink/blink"
  else
    die "blink not found. Set BLINK_BIN=/path/to/blink or put it on PATH."
  fi
fi
export BLINK_BIN

# ROOTFS: required.
if [ -z "${ROOTFS:-}" ]; then
  die "ROOTFS is not set. Export ROOTFS=/path/to/unpacked/alpine-minirootfs"
fi
[ -d "$ROOTFS" ] || die "ROOTFS directory does not exist: $ROOTFS"
[ -x "$ROOTFS/bin/sh" ] || [ -f "$ROOTFS/bin/busybox" ] \
  || die "ROOTFS does not look like an Alpine rootfs (no bin/sh or bin/busybox)"

# Network fixtures need a resolv.conf inside the rootfs (minirootfs ships
# none). If NETWORK=1 and one is missing, copy the host's.
if [ "$NETWORK" = "1" ] && [ ! -s "$ROOTFS/etc/resolv.conf" ]; then
  if [ -s /etc/resolv.conf ]; then
    cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null && \
      log "Copied host /etc/resolv.conf into rootfs for network tests."
  fi
fi

# `timeout` is used to hard-kill any hung fixture.
HAS_TIMEOUT=0
if command -v timeout >/dev/null 2>&1; then HAS_TIMEOUT=1; fi

# --------------------------------------------------------------------------
# Metadata parser
# --------------------------------------------------------------------------
parse_meta() {
  # Sets M_NAME, M_CATEGORY, M_CONTAINS, M_EXIT, M_TAGS via global vars.
  local f="$1"
  M_NAME="$(sed -n 's/^# FIXTURE: *//p' "$f" | head -1)"
  M_CATEGORY="$(sed -n 's/^# CATEGORY: *//p' "$f" | head -1)"
  M_CONTAINS="$(sed -n 's/^# EXPECT_CONTAINS: *//p' "$f" | head -1)"
  M_EXIT="$(sed -n 's/^# EXPECT_EXIT: *//p' "$f" | head -1)"
  M_TAGS="$(sed -n 's/^# TAGS: *//p' "$f" | head -1)"
  M_EXIT="${M_EXIT:-0}"
  [ -n "$M_NAME" ] || M_NAME="$(basename "$f")"
}

# --------------------------------------------------------------------------
# Discover fixtures (sorted by numeric prefix)
# --------------------------------------------------------------------------
# Discover fixtures (sorted by numeric prefix). Use a while-read loop instead
# of `mapfile`/`readarray` so the runner works with the bash 3.2 that ships
# with macOS as well as bash 4+ on Linux.
FIXTURES=()
while IFS= read -r _f; do
  [ -n "$_f" ] && FIXTURES+=("$_f")
done < <(find "$FIXTURE_DIR" -maxdepth 1 -name '*.sh' -type f | sort)
unset _f

if [ "$LIST_ONLY" = "1" ]; then
  printf '%-38s %-12s %-8s %s\n' "FIXTURE" "CATEGORY" "EXIT" "TAGS"
  for f in "${FIXTURES[@]}"; do
    parse_meta "$f"
    printf '%-38s %-12s %-8s %s\n' "$M_NAME" "$M_CATEGORY" "$M_EXIT" "$M_TAGS"
  done
  exit 0
fi

# --------------------------------------------------------------------------
# Reset gap log for this run. A persistent "Known gaps" section at the bottom
# of the file (delimited by the two markers below) is preserved across runs.
# --------------------------------------------------------------------------
RUN_TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
PERSIST_MARK="## Known gaps (persistent, hand-triaged)"
OLD_PERSIST=""
if [ -f "$GAP_LOG" ]; then
  # Grab everything from the persistent marker line onward, if present.
  # Use grep -n to find the line, then sed to print from there to EOF.
  _pl="$(grep -nF "$PERSIST_MARK" "$GAP_LOG" | head -1 | cut -d: -f1)"
  if [ -n "$_pl" ]; then
    OLD_PERSIST="$(sed -n "${_pl},\$p" "$GAP_LOG")"
  fi
fi
{
  echo "# SYSCALL-GAP-LOG"
  echo ""
  echo "Auto-generated by \`run-all.sh\`. Failures (missing/incorrect syscall"
  echo "behavior under Blink) are appended here on every run."
  echo ""
  echo "## Latest run"
  echo ""
  echo "<!-- RUN-AUTO-GENERATED-START -->"
  echo "### Run: $RUN_TS"
  echo ""
  echo "- blink: \`$BLINK_BIN\` ($("$BLINK_BIN" -v 2>/dev/null | head -1))"
  echo "- rootfs: \`$ROOTFS\`"
  echo "- network: $NETWORK"
  echo "- host: $(uname -srm)"
  echo ""
} > "$GAP_LOG"

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()
FAILED_DETAILS=()

log "${C_BOLD}Tether Linux/Blink test harness${C_RST}"
log "  blink : $BLINK_BIN"
log "  rootfs: $ROOTFS"
log "  network fixtures: $NETWORK"
log "  discovered: ${#FIXTURES[@]} fixtures"
log ""

run_one() {
  local f="$1"
  parse_meta "$f"

  # Skip network fixtures in offline mode.
  case " $M_TAGS " in
    *" network "*)
      if [ "$NETWORK" != "1" ]; then
        printf '  %sSKIP%s  %-34s (network)\n' "$C_SKIP" "$C_RST" "$M_NAME"
        SKIP=$((SKIP+1))
        return 0
      fi ;;
  esac

  local output rc
  if [ "$HAS_TIMEOUT" = "1" ]; then
    output="$(timeout --signal=KILL "$TIMEOUT_SECS" env ROOTFS="$ROOTFS" BLINK_BIN="$BLINK_BIN" sh "$f" 2>&1)"
    rc=$?
    # timeout exits 137 (128+9) when it had to kill.
    if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
      output="[TIMEOUT after ${TIMEOUT_SECS}s]
$output"
    fi
  else
    output="$(env ROOTFS="$ROOTFS" BLINK_BIN="$BLINK_BIN" sh "$f" 2>&1)"
    rc=$?
  fi

  local ok=1 reasons=""
  if [ "$rc" != "$M_EXIT" ]; then
    ok=0
    reasons="expected exit $M_EXIT, got $rc"
  fi
  if [ -n "$M_CONTAINS" ]; then
    if ! printf '%s' "$output" | grep -qF -- "$M_CONTAINS"; then
      ok=0
      [ -n "$reasons" ] && reasons="$reasons; "
      reasons="${reasons}missing substring '$M_CONTAINS'"
    fi
  fi

  if [ "$ok" = "1" ]; then
    PASS=$((PASS+1))
    printf '  %sPASS%s  %s\n' "$C_OK" "$C_RST" "$M_NAME"
    [ "$VERBOSE" = "1" ] && printf '%s\n' "$output" | sed 's/^/        | /'
  else
    FAIL=$((FAIL+1))
    FAILED_NAMES+=("$M_NAME")
    FAILED_DETAILS+=("exit=$rc expected=$M_EXIT :: $reasons")
    printf '  %sFAIL%s  %-34s %s\n' "$C_FAIL" "$C_RST" "$M_NAME" "$reasons"
    [ "$VERBOSE" = "1" ] && printf '%s\n' "$output" | sed 's/^/        | /'
    # Append to gap log.
    {
      echo "### FAIL: $M_NAME"
      echo ""
      echo "- category: $M_CATEGORY"
      echo "- file: \`$(basename "$f")\`"
      echo "- reason: $reasons"
      echo "- stderr/output snippet:"
      echo '```'
      printf '%s\n' "$output" | tail -n 15
      echo '```'
      echo ""
    } >> "$GAP_LOG"
  fi
}

for f in "${FIXTURES[@]}"; do
  run_one "$f"
done

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
TOTAL=$((PASS+FAIL+SKIP))
log ""
log "${C_BOLD}Results:${C_RST}  ${C_OK}PASS: $PASS${C_RST}  ${C_FAIL}FAIL: $FAIL${C_RST}  ${C_SKIP}SKIP: $SKIP${C_RST}  (total $TOTAL)"

if [ "$FAIL" -gt 0 ]; then
  {
    echo "### Failures ($FAIL)"
    echo ""
    echo "FAIL count: $FAIL / $((PASS+FAIL)) run (skipped: $SKIP)"
    echo ""
    echo "| Fixture | Detail |"
    echo "|---------|--------|"
    for i in "${!FAILED_NAMES[@]}"; do
      echo "| ${FAILED_NAMES[$i]} | ${FAILED_DETAILS[$i]} |"
    done
    echo ""
  } >> "$GAP_LOG"
else
  {
    echo "All $PASS run fixtures passed (skipped: $SKIP)."
    echo ""
  } >> "$GAP_LOG"
fi

echo "<!-- RUN-AUTO-GENERATED-END -->" >> "$GAP_LOG"
echo "" >> "$GAP_LOG"
# Re-append persistent known-gaps section if one existed.
if [ -n "$OLD_PERSIST" ]; then
  printf '%s\n' "$OLD_PERSIST" >> "$GAP_LOG"
else
  cat >> "$GAP_LOG" <<'PG'
## Known gaps (persistent, hand-triaged)

_No persistent gaps documented yet. See SYSCALL-GAP-LOG history or the
fixture comments for details on any Blink limitations._
PG
fi

if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
