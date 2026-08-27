'use strict';

// Fixture: run the shim against an in-process mock server, then receive a
// tty.signal. Used by default-actions.test.js to observe real exit codes.
//
// Usage: node signal-exit.js <SIGNAL> [listen]
//
// Armed only via TETHER_FIXTURE_ARM=1 (set by default-actions.test.js) so
// that `node --test test/` walking this directory treats the file as an
// inert module instead of executing the scenario.

if (process.env.TETHER_FIXTURE_ARM === '1') {
  main();
}

function main() {
  const { install } = require('../../lib');
  const { MockServer } = require('../harness/mock-server');

  const signal = process.argv[2] || 'SIGINT';
  const withListener = process.argv[3] === 'listen';

  const server = new MockServer({ ttyFds: [0, 1, 2] });

  install({ connect: () => server.createConnection() }).then(
    () => {
      if (withListener) {
        process.on(signal, () => {
          process.stdout.write('handled\n');
          process.exit(0);
        });
      }
      server.push('tty.signal', { signal });
      // For signals whose default action is a no-op (SIGTSTP/SIGCONT/SIGHUP
      // without listeners), reaching here means the shim correctly did nothing.
      setImmediate(() => {
        process.stdout.write('survived\n');
        process.exit(0);
      });
    },
    (err) => {
      process.stderr.write(`fixture install failed: ${err.message}\n`);
      process.exit(2);
    }
  );
}
