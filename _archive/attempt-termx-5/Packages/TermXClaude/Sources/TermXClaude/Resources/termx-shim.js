'use strict';
const native = globalThis.__termx_native || {};
const real = require('node:child_process');
function routedSpawn(file, args = [], options = {}, callback) {
  if (typeof args === 'function') { callback = args; args = []; options = {}; }
  const child = native.spawn ? native.spawn(file, args, options) : real.spawn(file, args, { ...options, shell: false });
  if (callback) child.once('error', callback);
  return child;
}
function routedExec(command, options, callback) {
  if (typeof options === 'function') { callback = options; options = {}; }
  const child = routedSpawn('sh', ['-c', command], options);
  let stdout = '', stderr = '';
  child.stdout?.on('data', b => { stdout += b; }); child.stderr?.on('data', b => { stderr += b; });
  child.once('close', code => callback?.(code ? new Error(stderr || `exit ${code}`) : null, stdout, stderr));
  return child;
}
function routedSync(command, options = {}) { const result = native.spawnSync ? native.spawnSync('sh', ['-c', command], options) : real.spawnSync('sh', ['-c', command], options); if (result.error) throw result.error; return result.stdout; }
module.exports = { ...real, spawn: routedSpawn, exec: routedExec, execSync: routedSync, spawnSync: (file, args = [], options = {}) => native.spawnSync ? native.spawnSync(file, args, options) : real.spawnSync(file, args, options), fork: (modulePath, args = [], options = {}) => routedSpawn(process.execPath, [modulePath, ...args], options) };
