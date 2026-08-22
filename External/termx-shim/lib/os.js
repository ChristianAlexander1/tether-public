'use strict';

/**
 * lib/os.js — platform overrides so Node reports the (virtualised) target
 * environment of the iOS host rather than the machine this shim runs on.
 * Everything not overridden passes through to the real `os` module.
 */

const real = require('os');

module.exports = Object.assign({}, real, {
  /** The app always targets an iOS device, which is Darwin. */
  platform() {
    return 'darwin';
  },
  type() {
    return 'Darwin';
  },
  /** Modern iPhones are arm64. */
  arch() {
    return 'arm64';
  },
  homedir() {
    return process.env.HOME || real.homedir();
  },
  tmpdir() {
    return process.env.TMPDIR || real.tmpdir();
  },
  release() {
    return '23.4.0';
  },
  cpus() {
    return [
      { model: 'Apple A17 Pro', speed: 3780, times: { user: 0, nice: 0, sys: 0, idle: 100, irq: 0 } },
      { model: 'Apple A17 Pro', speed: 3780, times: { user: 0, nice: 0, sys: 0, idle: 100, irq: 0 } },
      { model: 'Apple A17 Pro', speed: 3780, times: { user: 0, nice: 0, sys: 0, idle: 100, irq: 0 } },
      { model: 'Apple A17 Pro', speed: 3780, times: { user: 0, nice: 0, sys: 0, idle: 100, irq: 0 } },
    ];
  },
  totalmem() {
    return 0x200000000; // 8 GiB, in bytes
  },
  freemem() {
    return 0x100000000; // 4 GiB, in bytes
  },
  endianness() {
    return 'LE';
  },
  EOL: '\n',
});
