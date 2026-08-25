#!/usr/bin/env node
'use strict'
// Claude Code launcher for TermX: run the extracted JS bundle under Node.
// Technique adapted from the Apache-2.0 QNX Claude Code port (qnx/claude-code-qnx).

const Module = require('module')
const path = require('path')
const fs = require('fs')

require('./bun-shim.js')

// ESM imports of Node built-ins do not pass through Module._load. Mirror the
// already-installed Tether built-in shims into Node's live ESM export cells so
// split Claude bundles get the same real guest process bridge as CommonJS.
;(function syncTetherBuiltinsForESM() {
  if (typeof Module.syncBuiltinESMExports !== 'function') return
  const tetherLoad = Module._load
  const rawLoad = tetherLoad._tetherOriginalLoad
  if (typeof rawLoad !== 'function') return
  for (const name of ['child_process', 'os', 'tty']) {
    try {
      const nativeModule = rawLoad(name, module, false)
      const tetherModule = tetherLoad(name, module, false)
      for (const key of Object.keys(tetherModule)) {
        try { nativeModule[key] = tetherModule[key] } catch (_) { /* read-only export */ }
      }
    } catch (_) { /* optional built-in surface */ }
  }
  Module.syncBuiltinESMExports()
})()

// Extracted Claude JS assumes platform linux (Bun linux bundle). Ensure browser open
// is attempted — otherwise h_f() returns no_display and OAuth never spawns xdg-open.
process.env.DISPLAY = process.env.DISPLAY || ':0'
process.env.WAYLAND_DISPLAY = process.env.WAYLAND_DISPLAY || 'tether'
process.env.BROWSER = process.env.BROWSER || 'open'

// NodeMobile / jitless V8 ships a broken Intl.Segmenter (null deref in
// JSSegments::Create). Claude's interactive TUI calls it and SIGSEGVs the app.
// Always replace — a sync probe can pass and still crash on later inputs.
;(function polyfillIntlSegmenter() {
  class Segmenter {
    constructor(locales, options) {
      this._locale = typeof locales === 'string' ? locales
        : Array.isArray(locales) ? (locales[0] || 'en') : 'en'
      this._granularity = (options && options.granularity) || 'grapheme'
    }
    resolvedOptions() {
      return { locale: this._locale, granularity: this._granularity }
    }
    segment(input) {
      const str = String(input ?? '')
      const granularity = this._granularity
      const parts = []
      if (granularity === 'word') {
        const re = /(\s+)|(\S+)/g
        let m
        while ((m = re.exec(str))) {
          parts.push({
            segment: m[0],
            index: m.index,
            isWordLike: Boolean(m[2]),
          })
        }
      } else if (granularity === 'sentence') {
        const re = /[^.!?]+[.!?]+|[^.!?]+$/g
        let m
        while ((m = re.exec(str))) {
          parts.push({ segment: m[0], index: m.index })
        }
        if (!parts.length && str) parts.push({ segment: str, index: 0 })
      } else {
        let index = 0
        for (const ch of str) {
          parts.push({ segment: ch, index })
          index += ch.length
        }
      }
      return {
        *[Symbol.iterator]() {
          for (const p of parts) yield p
        },
        containing(codeUnitIndex) {
          const i = Number(codeUnitIndex) || 0
          for (let n = parts.length - 1; n >= 0; --n) {
            if (i >= parts[n].index) return parts[n]
          }
          return parts[0] || { segment: '', index: 0 }
        },
      }
    }
    static supportedLocalesOf(locales) {
      return Array.isArray(locales) ? locales.map(String) : [String(locales || 'en')]
    }
  }
  try {
    if (typeof Intl === 'undefined') return
    Object.defineProperty(Intl, 'Segmenter', {
      value: Segmenter,
      writable: true,
      configurable: true,
      enumerable: false,
    })
  } catch (_) {
    try { Intl.Segmenter = Segmenter } catch (_) { /* ignore */ }
  }
})()

// nodejs-mobile is one persistent engine, so this launcher can execute more than
// once in the same process. Install the loader hook once instead of wrapping an
// already-wrapped Module._load after every invocation.
const bunfsInterceptorKey = Symbol.for('tether.claude.bunfs-interceptor')
if (!Module[bunfsInterceptorKey]) {
  const originalLoad = Module._load
  Module._load = function bunfsInterceptor(request, parent, isMain) {
    const extractedRoot = process.env.CLAUDE_BUNFS_ROOT
    const extractedBundle = extractedRoot && path.dirname(extractedRoot)
    const isExtractedNative = extractedBundle && path.extname(request) === '.node' &&
      (request === extractedBundle || request.startsWith(extractedBundle + path.sep))
    if (request.startsWith('/$bunfs/') || request.startsWith('$bunfs/') || isExtractedNative) {
      if (path.extname(request) === '.node') {
        return {}
      }
      return { exports: {} }
    }
    return originalLoad.apply(this, arguments)
  }
  Module[bunfsInterceptorKey] = true
}

const claudeCodePath = process.env.CLAUDE_CODE_JS ||
  path.join(__dirname, 'claude-code.js')

if (!fs.existsSync(claudeCodePath)) {
  console.error(`[tether-claude] Claude Code entry not found at: ${claudeCodePath}`)
  console.error('Run claude once to install (downloads latest and extracts the JS app).')
  process.exit(1)
}

if (process.env.CLAUDE_CODE_ESM === '1') {
  const { pathToFileURL } = require('url')
  const runKey = Symbol.for('tether.claude.esm-run')
  global[runKey] = Number(global[runKey] || 0) + 1
  const sourceRoot = process.env.CLAUDE_BUNFS_ROOT || path.dirname(claudeCodePath)
  const bundleRoot = path.dirname(sourceRoot)
  const runsRoot = path.join(bundleRoot, '.runs')
  const runRoot = path.join(
    runsRoot,
    `${Date.now()}-${global[runKey]}`,
    'root'
  )

  // nodejs-mobile is one persistent engine and Node does not expose an API to
  // evict ESM modules. Bun split chunks contain stateful one-shot initializers,
  // so reusing their cache corrupts later commands. Give each job a unique
  // graph path. APFS clone mode is copy-on-write; only the rewritten JS pages
  // consume new blocks, and the previous completed job is removed first.
  function cloneFreshGraph(source, destination) {
    fs.rmSync(runsRoot, { recursive: true, force: true })
    fs.mkdirSync(destination, { recursive: true })
    const pending = [[source, destination]]
    while (pending.length) {
      const [from, to] = pending.pop()
      for (const item of fs.readdirSync(from, { withFileTypes: true })) {
        const src = path.join(from, item.name)
        const dst = path.join(to, item.name)
        if (item.isDirectory()) {
          fs.mkdirSync(dst, { recursive: true })
          pending.push([src, dst])
          continue
        }
        if (!item.isFile()) continue
        try {
          fs.copyFileSync(src, dst, fs.constants.COPYFILE_FICLONE)
        } catch (_) {
          fs.copyFileSync(src, dst)
        }
      }
    }

    const oldPrefix = source + path.sep
    const newPrefix = destination + path.sep
    const rewrite = [destination]
    while (rewrite.length) {
      const directory = rewrite.pop()
      for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
        const file = path.join(directory, item.name)
        if (item.isDirectory()) {
          rewrite.push(file)
        } else if (item.isFile() && (file.endsWith('.js') || file.endsWith('.mjs'))) {
          const original = fs.readFileSync(file, 'utf8')
          let text = original
          if (text.includes(oldPrefix)) {
            text = text.split(oldPrefix).join(newPrefix)
          }

          // Bun supplies import.meta.require to standalone module graphs; Node's
          // standards-based equivalent is createRequire(import.meta.url). Apply
          // that compatibility transform to every affected module, preserving
          // per-file resolution semantics without knowing anything about the
          // application or its commands.
          if (text.includes('import.meta.require')) {
            const binding = '__tetherImportMetaRequire_7f3a9c'
            text = `import { createRequire as __tetherCreateRequire_7f3a9c } from "node:module";\n` +
              `const ${binding} = __tetherCreateRequire_7f3a9c(import.meta.url);\n` +
              text.split('import.meta.require').join(binding)
          }
          if (text !== original) fs.writeFileSync(file, text)
        }
      }
    }
  }

  cloneFreshGraph(sourceRoot, runRoot)
  const freshEntry = path.join(runRoot, path.basename(claudeCodePath))
  process.once('exit', () => {
    try { fs.rmSync(path.dirname(runRoot), { recursive: true, force: true }) } catch (_) {}
  })
  module.exports = import(pathToFileURL(freshEntry).href)
  return
}

// bootstrap.js evicts this launcher between jobs. The extracted application is
// a second module, however, and Node would otherwise return its cached exports
// immediately on the next `claude` command. Evict the real entry point as well
// so every shell invocation starts a fresh CLI lifecycle.
const resolvedClaudeCodePath = require.resolve(claudeCodePath)
delete require.cache[resolvedClaudeCodePath]
require(resolvedClaudeCodePath)
