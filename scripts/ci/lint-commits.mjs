// Lint a commit range against .commitlintrc.yml and emit per-commit results.
//
// Usage: node scripts/ci/lint-commits.mjs <base-sha> <head-sha> [config-file]
// Requires `npm ci --ignore-scripts` first (root package.json/lockfile).
//
// Replaces wagoid/commitlint-github-action with the same @commitlint libraries it
// wrapped, installed from the committed lockfile (integrity-hashed, --ignore-scripts).
// The output contract is kept identical so the sticky-comment builder in ci.yml is
// untouched: a `results` GITHUB_OUTPUT of [{hash, message, valid, errors[], warnings[]}].
//
// Range semantics vs the action: the action listed commits via the GitHub API (capped at
// 100 commits per event); this reads git directly, so it needs the fetch-depth: 0 checkout
// and has no cap. Merge commits pass via commitlint's defaultIgnores, as before.
//
// NOTE: `extends:` presets resolve by walking up from the CONFIG FILE's directory
// (@commitlint/load derives its resolution base from the config path, not from this
// script) — which is why the package.json/node_modules live at the repo root.
import { appendFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { resolve } from 'node:path'
import load from '@commitlint/load'
import lint from '@commitlint/lint'

const ZERO_SHA = '0'.repeat(40)
const [, , baseSha = '', headSha = '', configFile = '.commitlintrc.yml'] = process.argv

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' })

const listCommits = () => {
  if (!headSha) return [] // workflow_dispatch: no range in the event — nothing to lint
  // First push of a ref has an all-zeros `before`; lint just the head commit then.
  const range = !baseSha || baseSha === ZERO_SHA ? ['--max-count=1', headSha] : [`${baseSha}..${headSha}`]
  const raw = git('log', '--reverse', '--format=%H%x00%B%x01', ...range)
  return raw
    .split('\x01')
    .map((s) => s.replace(/^\n/, ''))
    .filter(Boolean)
    .map((s) => {
      const i = s.indexOf('\x00')
      return { hash: s.slice(0, i), message: s.slice(i + 1).replace(/\s+$/, '') }
    })
}

const config = await load({}, { file: resolve(configFile) })
const opts = {
  parserOpts: config.parserPreset?.parserOpts ?? {},
  plugins: config.plugins ?? {},
  ignores: config.ignores ?? [],
  defaultIgnores: config.defaultIgnores ?? true,
}

const results = []
for (const commit of listCommits()) {
  const r = await lint(commit.message, config.rules, opts)
  results.push({
    hash: commit.hash,
    message: r.input,
    valid: r.valid,
    errors: r.errors.map((e) => e.message),
    warnings: r.warnings.map((w) => w.message),
  })
}

if (process.env.GITHUB_OUTPUT) {
  const delimiter = `results-${randomUUID()}`
  appendFileSync(process.env.GITHUB_OUTPUT, `results<<${delimiter}\n${JSON.stringify(results)}\n${delimiter}\n`)
}

const bad = results.filter((r) => !r.valid)
for (const r of results) {
  const subject = r.message.split('\n')[0]
  console.log(`${r.valid ? '✓' : '✗'} ${r.hash.slice(0, 7)} ${subject}`)
  for (const p of [...r.errors, ...r.warnings]) console.log(`    ${p}`)
}
console.log(`${results.length} commit(s) linted, ${bad.length} invalid`)
if (bad.length > 0) process.exitCode = 1
