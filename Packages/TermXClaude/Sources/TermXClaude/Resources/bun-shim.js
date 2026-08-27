'use strict'
// Bun API polyfill so Claude Code's extracted JS bundle runs under Node.
//
// The Bun surface itself lives in `tether-bun-compat` (External/, with its own
// test suite); this file is only the glue that is specific to running Claude
// Code here:
//
//   * YAML, which maps to the js-yaml the installer puts in place;
//   * semver ordering and the ANSI width/wrap helpers, which the bundle uses
//     and the compat library does not provide;
//   * `openInBrowser`, which goes through the platform opener.
//
// What is deliberately NOT here any more: a hardcoded list of opener names
// that `Bun.which` answered with a fabricated `/usr/bin/<name>` path. It
// reported success for launchers that were never installed and only ever knew
// the names someone had typed into this file. `Bun.which` now performs a real
// PATH scan (the guest launchers are on PATH), and the one list of opener
// names lives in `tether_dispatch_manifest.json`.

const cp = require('child_process')
const path = require('path')

const { installBunGlobal } = require('./bun-compat/lib/index.js')

function semverParts(v) {
  const m = String(v).match(/^(\d+)\.(\d+)\.(\d+)(-(.+))?/)
  if (!m) return [0, 0, 0, false]
  return [+m[1], +m[2], +m[3], Boolean(m[4])]
}

function semverOrder(a, b) {
  const [a1, a2, a3, ap] = semverParts(a)
  const [b1, b2, b3, bp] = semverParts(b)
  for (const [x, y] of [[a1, b1], [a2, b2], [a3, b3]]) {
    if (x !== y) return x > y ? 1 : -1
  }
  if (ap !== bp) return ap ? -1 : 1
  return 0
}

const ANSI_RE = /\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))/g

function stripANSI(str) {
  return str.replace(ANSI_RE, '')
}

function bunStringWidth(str) {
  const clean = stripANSI(str)
  let w = 0
  for (const char of clean) {
    const cp = char.codePointAt(0)
    if (cp <= 0x1F || (cp >= 0x7F && cp <= 0x9F)) continue
    if ((cp >= 0x0300 && cp <= 0x036F) ||
        (cp >= 0x1AB0 && cp <= 0x1AFF) ||
        (cp >= 0x20D0 && cp <= 0x20FF) ||
        (cp >= 0xFE20 && cp <= 0xFE2F) ||
        cp === 0x200B || cp === 0xFEFF) continue
    if ((cp >= 0x1100 && cp <= 0x115F) ||
        cp === 0x2329 || cp === 0x232A ||
        (cp >= 0x2E80 && cp <= 0x303E) ||
        (cp >= 0x3040 && cp <= 0xA4C6) ||
        (cp >= 0xA960 && cp <= 0xA97C) ||
        (cp >= 0xAC00 && cp <= 0xD7A3) ||
        (cp >= 0xF900 && cp <= 0xFAFF) ||
        (cp >= 0xFE10 && cp <= 0xFE19) ||
        (cp >= 0xFE30 && cp <= 0xFE6B) ||
        (cp >= 0xFF01 && cp <= 0xFF60) ||
        (cp >= 0xFFE0 && cp <= 0xFFE6) ||
        cp >= 0x1B000) {
      w += 2
    } else {
      w += 1
    }
  }
  return w
}

function bunWrapAnsi(str, cols) {
  if (!cols || cols <= 0) return str
  const sw = bunStringWidth
  return str.split('\n').map(line => {
    if (sw(line) <= cols) return line
    const words = line.split(' ')
    const out = []
    let cur = '', curW = 0
    for (const word of words) {
      const ww = sw(word)
      const gap = cur ? 1 : 0
      if (curW + gap + ww <= cols) {
        cur = cur ? cur + ' ' + word : word
        curW += gap + ww
      } else {
        if (cur) out.push(cur)
        if (ww > cols) {
          let remaining = word
          while (sw(remaining) > cols) {
            out.push(remaining.slice(0, cols))
            remaining = remaining.slice(cols)
          }
          cur = remaining
          curW = sw(remaining)
        } else {
          cur = word
          curW = ww
        }
      }
    }
    if (cur) out.push(cur)
    return out.join('\n')
  }).join('\n')
}

let jsYaml
try { jsYaml = require('js-yaml') } catch {}

// `child_process` here is the shim'd module: on the TJIP/2 lane `require`
// returns tether-shim-v2's implementation, so Bun.spawn goes over the protocol
// like every other child process rather than around it.
const Bun = installBunGlobal({
  force: true,
  version: '1.3.14-tether-shim',
  spawnImpl: cp,
  fs: require('fs'),
  env: process.env,
  pathDirs: (process.env.PATH || '').split(path.delimiter).filter(Boolean),
})

/// The platform opener, named by the host from the dispatch manifest. No
/// opener name is written in this file.
function platformOpener() {
  return process.env.TETHER_OPENER || process.env.BROWSER || null
}

Object.assign(Bun, {
  semver: {
    order: semverOrder,
    satisfies() { return true },
  },
  YAML: {
    parse(s) {
      if (jsYaml) return jsYaml.load(s)
      throw new Error('[tether bun-shim] YAML.parse needs js-yaml')
    },
    stringify(obj, _replacer, indent) {
      if (jsYaml) return jsYaml.dump(obj, { indent: indent ?? 2 })
      throw new Error('[tether bun-shim] YAML.stringify needs js-yaml')
    },
  },
  JSONL: { parseChunk: null },
  openInBrowser(url) {
    const u = String(url || '')
    const opener = platformOpener()
    if (!u || !opener) return Promise.resolve()
    // Intercepted at the spawn layer by SystemOpen, which turns it into an
    // in-app browser presentation.
    return Promise.resolve(cp.spawnSync(opener, [u]))
  },
  wrapAnsi: bunWrapAnsi,
  stripANSI,
  stringWidth(str) { return bunStringWidth(str) },
  embeddedFiles: [],
  generateHeapSnapshot() { return new ArrayBuffer(0) },
  Terminal: null,
  Transpiler: null,
  stdin: process.stdin,
})

module.exports = Bun
