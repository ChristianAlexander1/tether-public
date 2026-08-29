'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const launcher = path.resolve(
  __dirname,
  '../../Sources/TermXClaude/Resources/launcher.js'
);

test('Claude launcher loads assets, synchronizes ESM built-ins, and reinstalls its hook', (t) => {
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'tether-claude-launcher-'));
  t.after(() => fs.rmSync(temporaryDirectory, { recursive: true, force: true }));

  const sourceRoot = path.join(temporaryDirectory, 'root');
  fs.mkdirSync(sourceRoot);
  const markdownPath = path.join(sourceRoot, 'prompt.md');
  const textPath = path.join(sourceRoot, 'message.txt');
  const assetPath = path.join(sourceRoot, 'payload.asset');
  const entryPath = path.join(sourceRoot, '__tether_entry__.mjs');
  fs.writeFileSync(markdownPath, '# Autonomous loop check\n');
  fs.writeFileSync(textPath, 'plain text fixture\n');
  fs.writeFileSync(assetPath, 'opaque fixture\n');
  fs.writeFileSync(entryPath, `
    import childProcess, { spawn as esmSpawn } from 'node:child_process';
    const markdown = import.meta.require(${JSON.stringify(markdownPath)});
    const text = import.meta.require(${JSON.stringify(textPath)});
    const asset = import.meta.require(${JSON.stringify(assetPath)});
    if (markdown !== '# Autonomous loop check\\n') throw new Error('Markdown was not loaded as text');
    if (text !== 'plain text fixture\\n') throw new Error('Text was not loaded as text');
    if (typeof asset !== 'string' || !asset.endsWith('/payload.asset')) {
      throw new Error('Opaque asset was not loaded as a path');
    }
    const namedChild = esmSpawn('open', ['https://example.com']);
    const defaultChild = childProcess.spawn('open', ['https://example.com']);
    if (!namedChild.__tetherFixture || !defaultChild.__tetherFixture) {
      throw new Error('ESM child_process did not receive the active Tether shim');
    }
    if (namedChild.unref() !== namedChild || defaultChild.ref() !== defaultChild) {
      throw new Error('ESM child_process did not preserve the ChildProcess contract');
    }
    globalThis.__tetherClaudeFixtureRuns = (globalThis.__tetherClaudeFixtureRuns || 0) + 1;
    console.log('fixture-run-' + globalThis.__tetherClaudeFixtureRuns);
  `);

  const driverPath = path.join(temporaryDirectory, 'driver.cjs');
  fs.writeFileSync(driverPath, `
    const assert = require('node:assert/strict');
    const Module = require('node:module');
    const nativeChildProcess = require('node:child_process');
    const launcher = ${JSON.stringify(launcher)};
    const hookKey = Symbol.for('tether.claude.bunfs-interceptor');

    const nativeLoad = Module._load;
    const tetherChildProcess = {
      ...nativeChildProcess,
      spawn() {
        const child = {
          __tetherFixture: true,
          ref() { return this; },
          unref() { return this; },
        };
        return child;
      },
    };
    function tetherLoad(request, parent, isMain) {
      if (request === 'child_process' || request === 'node:child_process') {
        return tetherChildProcess;
      }
      return nativeLoad.apply(this, arguments);
    }
    tetherLoad._tetherOriginalLoad = nativeLoad;
    Module._load = tetherLoad;

    async function launch() {
      delete require.cache[require.resolve(launcher)];
      await require(launcher);
    }

    (async () => {
      await launch();
      const firstHook = Module[hookKey];
      assert.equal(typeof firstHook, 'function');
      assert.equal(Module._load, firstHook);

      // The persistent runtime restores its own module loader after each job.
      // The next launcher invocation must notice and install a fresh wrapper.
      Module._load = firstHook._tetherOriginalLoad;
      await launch();
      assert.equal(typeof Module[hookKey], 'function');
      assert.equal(Module._load, Module[hookKey]);
    })().catch((error) => {
      console.error(error && error.stack || error);
      process.exitCode = 1;
    });
  `);

  const result = spawnSync(process.execPath, [driverPath], {
    cwd: temporaryDirectory,
    encoding: 'utf8',
    env: {
      ...process.env,
      CLAUDE_CODE_ESM: '1',
      CLAUDE_CODE_JS: entryPath,
      CLAUDE_BUNFS_ROOT: sourceRoot,
    },
  });

  assert.equal(result.status, 0, `stderr:\n${result.stderr}\nstdout:\n${result.stdout}`);
  assert.match(result.stdout, /fixture-run-1/);
  assert.match(result.stdout, /fixture-run-2/);
  assert.equal(result.stderr, '');
});
