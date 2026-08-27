import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

// v1 lane only: the TJIP/2 (v2) shim owns its own connection lifecycle, and
// v1's newline-JSON client must never be pointed at a v2 framed server.
if (process.env.TETHER_IPC_V2 !== '1'
    && (process.env.TETHER_IPC_SOCK || process.env.TERMX_IPC_SOCKET)) {
  const ipc = require('./lib/ipc.js');
  await ipc.connect();
}
