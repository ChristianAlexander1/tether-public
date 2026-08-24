#!/usr/bin/env node
'use strict'
// Claude Code launcher for TermX: run the extracted JS bundle under Node.
// Technique adapted from the Apache-2.0 QNX Claude Code port (qnx/claude-code-qnx).

const Module = require('module')
const path = require('path')
const fs = require('fs')

require('./bun-shim.js')

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

const _origLoad = Module._load
Module._load = function bunfsInterceptor(request, parent, isMain) {
  if (request.startsWith('/$bunfs/') || request.startsWith('$bunfs/')) {
    if (path.extname(request) === '.node') {
      return {}
    }
    return { exports: {} }
  }
  return _origLoad.apply(this, arguments)
}

const claudeCodePath = process.env.CLAUDE_CODE_JS ||
  path.join(__dirname, 'claude-code.js')

if (!fs.existsSync(claudeCodePath)) {
  console.error(`[termx-claude] claude-code.js not found at: ${claudeCodePath}`)
  console.error('Run claude once to install (downloads latest and extracts the JS app).')
  process.exit(1)
}

require(claudeCodePath)
