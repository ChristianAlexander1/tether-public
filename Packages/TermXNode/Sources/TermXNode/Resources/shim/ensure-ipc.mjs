import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ipc = require('./lib/ipc.js');

if (process.env.TETHER_IPC_SOCK || process.env.TERMX_IPC_SOCKET) {
  await ipc.connect();
}
