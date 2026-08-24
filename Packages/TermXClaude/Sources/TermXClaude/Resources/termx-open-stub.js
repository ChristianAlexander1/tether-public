'use strict'
// TermX stub for the npm `open` package — routes to platform opener via child_process IPC.
const cp = require('child_process')

function termxOpen(target, options) {
  const url = target == null ? '' : String(target)
  if (!url) return Promise.resolve()
  cp.spawnSync('open', [url])
  if (options && options.wait) {
    return Promise.resolve({ exitCode: 0 })
  }
  return Promise.resolve()
}

termxOpen.sync = function syncOpen(target) {
  const url = target == null ? '' : String(target)
  if (!url) return
  cp.spawnSync('open', [url])
}

module.exports = termxOpen
module.exports.default = termxOpen
