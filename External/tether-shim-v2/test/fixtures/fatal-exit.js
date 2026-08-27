'use strict';

// Fixture: run the shim, then inject a malformed frame (invalid JSON) on the
// wire. The shim must print exactly one line
//   tether-shim: IPC connection lost (<reason>)
// to stderr and exit(1) — never hang, never silently degrade.
//
// Armed only via TETHER_FIXTURE_ARM=1 (see signal-exit.js for why).

if (process.env.TETHER_FIXTURE_ARM === '1') {
  main();
}

function main() {
  const { install } = require('../../lib');
  const { MockServer } = require('../harness/mock-server');

  const server = new MockServer({ ttyFds: [0, 1, 2] });

  install({ connect: () => server.createConnection() }).then(
    () => {
      const bad = Buffer.alloc(4 + 3);
      bad.writeUInt32BE(3, 0);
      bad.write('zzz', 4); // not JSON → EPROTO → fatal
      server.injectRaw(bad);
      // If the shim hung or degraded silently, this timer would keep the
      // process alive and the parent test would time out — that is the point.
      setTimeout(() => {
        process.stdout.write('still-alive\n');
      }, 5000).unref?.();
    },
    (err) => {
      process.stderr.write(`fixture install failed: ${err.message}\n`);
      process.exit(2);
    }
  );
}
