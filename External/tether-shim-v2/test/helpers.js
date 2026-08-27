'use strict';

// Shared test utilities. Deterministic: promise/event awaiting only — no
// timer-based sleeps anywhere in the in-process suites.

const shim = require('../lib');
const { MockServer } = require('./harness/mock-server');

/**
 * Install the shim against a fresh mock server.
 * @param {object} [serverConfig] passed to MockServer
 * @param {object} [installOptions] extra install() options
 * @returns {Promise<{server: MockServer, session: {client: object, handshake: object}}>}
 */
async function setup(serverConfig = {}, installOptions = {}) {
  const server = new MockServer(serverConfig);
  const session = await shim.install({
    connect: () => server.createConnection(),
    ...installOptions,
  });
  return { server, session };
}

/** Await the next occurrence of an event; resolves with the listener args. */
function nextEvent(emitter, name) {
  return new Promise((resolve) => {
    emitter.once(name, (...args) => resolve(args));
  });
}

/** Collect every event occurrence into an array (unregistered on cleanup()). */
function collect(emitter, name) {
  const seen = [];
  const listener = (...args) => seen.push(args);
  emitter.on(name, listener);
  return {
    seen,
    cleanup() {
      emitter.off(name, listener);
    },
  };
}

/** Await a predicate checked after each macrotask tick (bounded, no sleeps). */
async function until(predicate, { limit = 10000, message = 'condition not met' } = {}) {
  for (let i = 0; i < limit; i++) {
    if (predicate()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  throw new Error(`until(): ${message}`);
}

/** Let queued microtasks + macrotasks settle a few turns. */
async function settle(turns = 3) {
  for (let i = 0; i < turns; i++) {
    await new Promise((resolve) => setImmediate(resolve));
  }
}

module.exports = { setup, nextEvent, collect, until, settle, shim, MockServer };
