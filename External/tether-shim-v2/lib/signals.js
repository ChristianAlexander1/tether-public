'use strict';

// tty.signal + tty.resize → process wiring.
//
// Resize ordering matters (Ink reads stdout.columns inside its resize
// handler): update columns/rows on ALL live streams first, then emit
// 'resize' on each, then emit 'SIGWINCH' on process — exactly once.

// One wiring per client (a process normally installs once; a fresh client
// after a test reset gets its own wiring, and double-attaching the same
// client is prevented).
const attachedClients = new WeakSet();

const KNOWN_SIGNALS = new Set(['SIGINT', 'SIGTERM', 'SIGTSTP', 'SIGCONT', 'SIGHUP']);

// Signos needed for the default-action exit code (128 + signo).
const DEFAULT_ACTION_SIGNO = { SIGINT: 2, SIGTERM: 15 };

function attach(context) {
  if (attachedClients.has(context.client)) return;
  attachedClients.add(context.client);

  context.client.on('evt:tty.resize', (body) => {
    const { cols, rows } = body || {};
    if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols <= 0 || rows <= 0) {
      return; // malformed body: ignore (unknown body fields are ignored per spec)
    }
    // Keep the canonical handshake geometry current, so streams constructed
    // later (tty.WriteStream, late installs of stdio props) see the latest
    // size rather than the original handshake snapshot.
    context.handshake.cols = cols;
    context.handshake.rows = rows;
    const streams = context.liveStreams();
    // Phase 1: update every live stream BEFORE any event fires.
    for (const stream of streams) {
      stream.columns = cols;
      stream.rows = rows;
    }
    // Phase 2: emit 'resize' on each stream.
    for (const stream of streams) {
      stream.emit('resize');
    }
    // Phase 3: process-level SIGWINCH, exactly once.
    process.emit('SIGWINCH');
  });

  context.client.on('evt:tty.signal', (body) => {
    const name = body && body.signal;
    if (!KNOWN_SIGNALS.has(name)) return; // unknown signal name: ignore

    if (Object.prototype.hasOwnProperty.call(DEFAULT_ACTION_SIGNO, name)) {
      if (process.listenerCount(name) === 0) {
        // Default action: SIGINT → 130, SIGTERM → 143.
        process.exit(128 + DEFAULT_ACTION_SIGNO[name]);
        return; // unreachable
      }
    }
    // SIGTSTP/SIGCONT/SIGHUP with zero listeners are no-ops by design:
    // there is no job-control suspend/resume semantics inside the host app
    // (no OS-level stopped state to return to), so dropping them is the only
    // honest behavior. With listeners present, deliver normally.
    process.emit(name);
  });
}

module.exports = { attach, KNOWN_SIGNALS, DEFAULT_ACTION_SIGNO };
