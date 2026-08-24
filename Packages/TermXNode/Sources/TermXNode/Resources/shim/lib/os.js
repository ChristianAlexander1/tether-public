'use strict';

// Forward Node's real operating-system implementation. The shim exists only so
// an embedded job can expose the HOME/TMPDIR chosen by the Tether session; it
// must not invent a platform, CPU topology, memory size, kernel version, UID,
// hostname, network interface, or priority behavior.
const Module = require('module');
const originalLoad = Module._load._tetherOriginalLoad || Module._load;
const nativeOS = originalLoad('node:os', module, false);

function homedir() {
  return process.env.HOME || nativeOS.homedir();
}

function tmpdir() {
  return process.env.TMPDIR || process.env.TMP || process.env.TEMP || nativeOS.tmpdir();
}

module.exports = {
  ...nativeOS,
  homedir,
  tmpdir,
};
