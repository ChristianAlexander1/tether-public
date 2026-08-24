'use strict';
const fs = require('fs');
const path = require('path');
const { MockHost } = require('./mock-host');

function loadFixture(name) {
  return JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', `${name}.json`), 'utf8'));
}
function replay(fixture, host = new MockHost()) {
  if (!fixture || !fixture.spawn) throw new TypeError('fixture must contain spawn');
  const result = host.handle(fixture.spawn);
  return { fixture, result, host };
}
function browserSpawn(env = {}, browser = env.BROWSER, url = 'https://example.com/') {
  if (!env.DISPLAY && !env.WAYLAND_DISPLAY) return null;
  const file = browser || 'xdg-open';
  return { kind: 'spawn', file, args: [url], cwd: '/work', env: { ...env }, interactive: false };
}
module.exports = { loadFixture, replay, browserSpawn };
