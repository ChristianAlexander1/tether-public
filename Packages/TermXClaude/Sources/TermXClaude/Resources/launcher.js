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
  for (const name of ['child_process', 'os', 'tty', 'http', 'https', 'dns', 'net']) {
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
// Claude's Vertex/AWS graphs probe EC2/GCE metadata at import time. There is
// no instance metadata on iOS; without this the ESM import never settles.
process.env.AWS_EC2_METADATA_DISABLED = process.env.AWS_EC2_METADATA_DISABLED || 'true'

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

// Bun's standalone graph supports non-JavaScript imports. The extractor writes
// those embedded files next to the split JS graph, but Node's CommonJS loader
// otherwise tries to compile (for example) a Markdown prompt as JavaScript.
// Mirror the Bun loaders used by Claude's graph at this boundary.
function isPathWithin(candidate, root) {
  const relative = path.relative(root, candidate)
  return relative === '' || (
    relative !== '..' &&
    !relative.startsWith('..' + path.sep) &&
    !path.isAbsolute(relative)
  )
}

function resolveExtractedRequest(request) {
  if (typeof request !== 'string') return null
  const extractedRoot = process.env.CLAUDE_BUNFS_ROOT
  if (!extractedRoot) return null

  const virtualRequest = request.startsWith('/$bunfs/')
    ? request.slice(1)
    : request
  if (virtualRequest === '$bunfs/root') return extractedRoot
  if (virtualRequest.startsWith('$bunfs/root/')) {
    const resolved = path.resolve(extractedRoot, virtualRequest.slice('$bunfs/root/'.length))
    return isPathWithin(resolved, extractedRoot) ? resolved : null
  }

  if (!path.isAbsolute(request)) return null
  const runsRoot = path.join(path.dirname(extractedRoot), '.runs')
  if (isPathWithin(request, extractedRoot) || isPathWithin(request, runsRoot)) {
    return request
  }
  return null
}

const noExtractedAsset = Symbol('tether.no-extracted-asset')
function loadExtractedAsset(request) {
  const extension = path.extname(request).toLowerCase()
  if (extension === '.md' || extension === '.txt') {
    return fs.readFileSync(request, 'utf8')
  }
  if (extension === '.asset') return request
  // Native Bun add-ons cannot be loaded by nodejs-mobile. Preserve the
  // compatibility fallback used before extracted text assets were supported.
  if (extension === '.node') return {}
  return noExtractedAsset
}

// nodejs-mobile is one persistent engine, so this launcher can execute more
// than once in the same process. The job runtime restores Module._load after a
// command finishes; keep the function itself as the marker so a later launcher
// can tell whether the hook is still active and reinstall it when necessary.
const bunfsInterceptorKey = Symbol.for('tether.claude.bunfs-interceptor')
if (typeof Module[bunfsInterceptorKey] !== 'function' ||
    Module._load !== Module[bunfsInterceptorKey]) {
  const originalLoad = Module._load
  function bunfsInterceptor(request, parent, isMain) {
    const extractedRequest = resolveExtractedRequest(request)
    if (extractedRequest) {
      const asset = loadExtractedAsset(extractedRequest)
      if (asset !== noExtractedAsset) return asset
      if (request.startsWith('/$bunfs/') || request.startsWith('$bunfs/')) {
        return originalLoad.call(this, extractedRequest, parent, isMain)
      }
    } else if (typeof request === 'string' &&
               (request.startsWith('/$bunfs/') || request.startsWith('$bunfs/'))) {
      return { exports: {} }
    }
    return originalLoad.apply(this, arguments)
  }
  bunfsInterceptor._tetherOriginalLoad = originalLoad
  Module._load = bunfsInterceptor
  Module[bunfsInterceptorKey] = bunfsInterceptor
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
          // Vertex upgrade statically imports ~150 AWS/GCP modules. Evaluating
          // that graph never settles on nodejs-mobile and `showSetupScreens`
          // awaits it before the first real Ink frame. iOS cannot use Vertex.
          if (
            text.includes('findVertexUpgradeCandidates') &&
            text.includes('tengu_vertex_upgrade_check')
          ) {
            text = [
              '// tether: Vertex upgrade graph omitted (no GCP on device)',
              'export async function findVertexUpgradeCandidates() { return [] }',
              'export async function checkVertexDefaultAvailability() { return [] }',
              'export async function probeVertexModel() { return false }',
              'export function seedEnvDefaultForUserPin() {}',
              '',
            ].join('\n')
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
