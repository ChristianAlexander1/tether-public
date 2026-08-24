'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const cp = require('../lib/child_process');
const { withIpc, collect } = require('./helper');

const URL = 'https://claude.ai/oauth/authorize?code=1';

describe('browser / OAuth spawns', () => {
  it('11 spawn open + https URL', async () => {
    await withIpc(async (backend) => {
      const r = await collect(cp.spawn('open', [URL], { env: { ...process.env, BROWSER: 'open' } }));
      assert.equal(r.code, 0);
      assert.match(r.stdout, /opened https:\/\//);
      const last = (await backend.dump()).last;
      assert.equal(last.file, 'open');
      assert.equal(last.args[0], URL);
    });
  });

  it('12 spawn xdg-open + DISPLAY=:0', async () => {
    await withIpc(async (backend) => {
      const env = { ...process.env, DISPLAY: ':0' };
      const r = await collect(cp.spawn('xdg-open', [URL], { env }));
      assert.equal(r.code, 0);
      const last = (await backend.dump()).last;
      assert.equal(last.file, 'xdg-open');
      assert.equal(last.env.DISPLAY, ':0');
    });
  });

  it('13 env DISPLAY/BROWSER preserved in JSON', async () => {
    await withIpc(async (backend) => {
      const env = {
        DISPLAY: ':1',
        BROWSER: 'open',
        WAYLAND_DISPLAY: 'wayland-0',
        PATH: '/usr/bin',
      };
      await collect(cp.spawn('sensible-browser', [URL], { env }));
      const last = (await backend.dump()).last;
      assert.equal(last.env.DISPLAY, ':1');
      assert.equal(last.env.BROWSER, 'open');
      assert.equal(last.env.WAYLAND_DISPLAY, 'wayland-0');
    });
  });

  it('sensible-browser spawn', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('sensible-browser', [URL]));
      assert.equal(r.code, 0);
    });
  });

  it('wslview spawn', async () => {
    await withIpc(async () => {
      const r = await collect(cp.spawn('wslview', [URL]));
      assert.equal(r.code, 0);
    });
  });

  it('parent env passed when options.env omitted', async () => {
    await withIpc(async (backend) => {
      process.env.DISPLAY = ':99';
      process.env.BROWSER = 'open';
      try {
        await collect(cp.spawn('open', [URL]));
        const last = (await backend.dump()).last;
        assert.equal(last.env.DISPLAY, ':99');
        assert.equal(last.env.BROWSER, 'open');
      } finally {
        delete process.env.DISPLAY;
        delete process.env.BROWSER;
      }
    });
  });

  it('open with BROWSER=open in process.env', async () => {
    await withIpc(async (backend) => {
      process.env.BROWSER = 'open';
      try {
        await collect(cp.spawn('open', ['https://example.com']));
        const last = (await backend.dump()).last;
        assert.equal(last.file, 'open');
        assert.equal(last.env.BROWSER, 'open');
      } finally {
        delete process.env.BROWSER;
      }
    });
  });
});
