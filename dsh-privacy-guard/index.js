/**
 * dsh-privacy-guard — privacy-checked updates for DeepSeek Harness.
 *
 * Host half. Registers:
 *   /dsh-privacy [status | poll | check <version> | update <version> | help]   slash command
 *   dsh_privacy_status, dsh_privacy_check                                      tools
 *   dsh-update                                                                  skill
 *   GET  /api/privacy-guard/status                                              authenticated routes
 *   POST /api/privacy-guard/{poll,check,update,restart}                         (web profile only)
 *
 * Polling: every `checkIntervalHours` the Host fetches the abbreviated metadata document for
 * @deepseek-ai/dsh from `registryUrl` (one small GET, no npm CLI, no identifying headers), compares
 * dist-tags with the pinned version, and runs the privacy check once for each newer version it has
 * not seen before. Results live in $DSH_HOME/tools/update-state.json.
 *
 * Updating: POST /update pins a version with `npm install --save-exact` in the private install prefix
 * ONLY when the stored privacy check for that version is CLEAN. POST /restart writes a marker the
 * `dsh` wrapper understands and stops the Host; the wrapper relaunches it on the new version.
 *
 * @module dsh-privacy-guard
 */

import { execFile } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { CommandDefinitionId } from '@deepseek-ai/dsh-commands/brand'

export const name = 'privacy-guard'
export const inject = ['commands', 'tools', 'skills', 'timer']

const PKG_DIR = dirname(fileURLToPath(import.meta.url))
const DSH_PACKAGE = '@deepseek-ai/dsh'
const STATE_VERSION = 1
const TAGS_TO_WATCH = ['latest', 'next']
const VERSION_RE = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u

/** Loader-validated configuration; every field has a resolved default at runtime. */
export const Config = z.object({
  /** Absolute path of dsh-privacy-check.sh. Default: $DSH_HOME/tools/, else the packaged copy. */
  checkerPath: z.string(),
  /** Absolute path of privacy-baseline.json. Default: $DSH_HOME/tools/, else the packaged copy. */
  baselinePath: z.string(),
  /** Private npm prefix that holds the pinned CLI. Default: ~/.dsh-cli. */
  installDir: z.string(),
  /** Deadline for one check or install run. */
  timeoutMs: z.number().step(1).min(1000).default(300_000),
  /** Hours between registry polls; 0 disables polling. */
  checkIntervalHours: z.number().min(0).default(24),
  /** npm-compatible registry origin to poll. */
  registryUrl: z.string().default('https://registry.npmjs.org'),
  /** Run the privacy check automatically for each newer version the poll discovers. */
  autoCheck: z.boolean().default(true),
})

// ---------------------------------------------------------------- paths + files

function dshHome() {
  return process.env.DSH_HOME && process.env.DSH_HOME !== '' ? process.env.DSH_HOME : join(homedir(), '.dsh')
}

function firstExisting(candidates) {
  return candidates.find((p) => p !== undefined && p !== '' && existsSync(p))
}

function resolvePaths(config) {
  const tools = join(dshHome(), 'tools')
  return {
    tools,
    checker: firstExisting([config.checkerPath, join(tools, 'dsh-privacy-check.sh'), join(PKG_DIR, 'scripts', 'dsh-privacy-check.sh')]),
    baseline: firstExisting([config.baselinePath, join(tools, 'privacy-baseline.json'), join(PKG_DIR, 'privacy-baseline.json')]),
    installDir: config.installDir && config.installDir !== '' ? config.installDir : join(homedir(), '.dsh-cli'),
    pinnedFile: join(tools, 'pinned-version'),
    stateFile: join(tools, 'update-state.json'),
    restartMarker: join(tools, 'restart-requested'),
    /** Written after a staged install; the dsh wrapper swaps the directories on the next restart. */
    pendingFile: join(tools, 'pending-install.json'),
  }
}

function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return undefined }
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, JSON.stringify(value, null, 2) + '\n')
}

// ---------------------------------------------------------------- semver (enough for npm release versions)

function parseVersion(v) {
  const m = VERSION_RE.test(v) ? v.match(/^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/u) : null
  if (!m) return undefined
  return { main: [Number(m[1]), Number(m[2]), Number(m[3])], pre: m[4] === undefined ? undefined : m[4].split('.') }
}

/** @returns negative when a < b, 0 when equal, positive when a > b; undefined when unparsable. */
function compareVersions(a, b) {
  const pa = parseVersion(a), pb = parseVersion(b)
  if (!pa || !pb) return undefined
  for (let i = 0; i < 3; i++) if (pa.main[i] !== pb.main[i]) return pa.main[i] - pb.main[i]
  if (pa.pre === undefined && pb.pre === undefined) return 0
  if (pa.pre === undefined) return 1
  if (pb.pre === undefined) return -1
  const n = Math.max(pa.pre.length, pb.pre.length)
  for (let i = 0; i < n; i++) {
    const x = pa.pre[i], y = pb.pre[i]
    if (x === undefined) return -1
    if (y === undefined) return 1
    const nx = /^\d+$/u.test(x), ny = /^\d+$/u.test(y)
    if (nx && ny) { if (Number(x) !== Number(y)) return Number(x) - Number(y) } else if (nx) return -1
    else if (ny) return 1
    else if (x !== y) return x < y ? -1 : 1
  }
  return 0
}

// ---------------------------------------------------------------- subprocess helpers

/** Run a command with a deadline; resolves with exit code and output, never rejects on non-zero exit. */
function run(file, args, { timeoutMs, signal, cwd } = {}) {
  return new Promise((resolve) => {
    const env = { ...process.env }
    env.PATH = `${dirname(process.execPath)}:${env.PATH ?? ''}`
    execFile(file, args, { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024, env, signal, cwd, encoding: 'utf8' }, (error, stdout, stderr) => {
      const code = error && typeof error.code === 'number' ? error.code : error ? (error.killed ? 124 : 2) : 0
      resolve({ code, stdout: stdout ?? '', stderr: stderr ?? '', error: error && typeof error.code !== 'number' ? error : undefined })
    })
  })
}

// ---------------------------------------------------------------- guard: state + operations

class Guard {
  constructor(ctx, config) {
    this.ctx = ctx
    this.config = config
    this.paths = resolvePaths(config)
    this.timeoutMs = config.timeoutMs ?? 300_000
    this.busy = undefined // name of the running operation
    this.state = this.loadState()
  }

  // -- persisted state -----------------------------------------------------
  loadState() {
    const stored = readJson(this.paths.stateFile)
    if (stored && stored.version === STATE_VERSION && typeof stored === 'object') return stored
    return { version: STATE_VERSION, lastPollAt: null, lastPollError: null, registryUrl: null, distTags: {}, candidates: {}, lastUpdate: null }
  }

  saveState() {
    try { writeJson(this.paths.stateFile, this.state) } catch (error) { this.ctx.logger.warn('privacy-guard: cannot write update-state.json: %o', error) }
  }

  // -- facts ---------------------------------------------------------------
  pinnedVersion() {
    const manifest = readJson(join(this.paths.installDir, 'package.json'))
    const fromManifest = manifest?.dependencies?.[DSH_PACKAGE]
    if (typeof fromManifest === 'string' && fromManifest !== '') return fromManifest
    try { return readFileSync(this.paths.pinnedFile, 'utf8').trim() || undefined } catch { return undefined }
  }

  installedVersion() {
    return readJson(join(this.paths.installDir, 'node_modules', DSH_PACKAGE, 'package.json'))?.version
  }

  baselineVersion() {
    return this.paths.baseline ? readJson(this.paths.baseline)?.version : undefined
  }

  registryHost() {
    try { return new URL(this.config.registryUrl).host } catch { return this.config.registryUrl }
  }

  /** Structured status for the UI, the command and the tool. */
  status() {
    const pinned = this.pinnedVersion()
    const candidates = Object.entries(this.state.candidates)
      .map(([version, c]) => ({ version, ...c, newer: pinned ? (compareVersions(version, pinned) ?? 0) > 0 : true }))
      .filter((c) => c.newer)
      .sort((a, b) => -(compareVersions(a.version, b.version) ?? 0))
    return {
      pinned: pinned ?? null,
      installed: this.installedVersion() ?? null,
      installDir: this.paths.installDir,
      baseline: this.baselineVersion() ?? null,
      checker: this.paths.checker ?? null,
      polling: {
        intervalHours: this.config.checkIntervalHours,
        registry: this.registryHost(),
        lastPollAt: this.state.lastPollAt,
        lastPollError: this.state.lastPollError,
        distTags: this.state.distTags,
      },
      candidates,
      busy: this.busy ?? null,
      lastUpdate: this.state.lastUpdate,
      pending: readJson(this.paths.pendingFile) ?? null,
      restartPending: existsSync(this.paths.pendingFile) || existsSync(this.paths.restartMarker),
    }
  }

  statusText() {
    const s = this.status()
    const lines = [
      `pinned version:    ${s.pinned ?? 'unknown'}`,
      `installed version: ${s.installed ?? 'unknown'} (${s.installDir})`,
      `running version:   ${this.installedVersionAtBoot ?? 'unknown'}`,
      `baseline:          ${s.baseline ?? 'unknown'} (${this.paths.baseline ?? 'missing'})`,
      `checker:           ${s.checker ?? 'missing'}`,
      s.polling.intervalHours > 0
        ? `polling:           every ${s.polling.intervalHours}h to ${s.polling.registry}, last ${s.polling.lastPollAt ?? 'never'}${s.polling.lastPollError ? ` (last error: ${s.polling.lastPollError})` : ''}`
        : 'polling:           off (set privacy-guard.checkIntervalHours)',
      `npm dist-tags:     ${Object.keys(s.polling.distTags).length ? Object.entries(s.polling.distTags).map(([k, v]) => `${k}=${v}`).join('  ') : 'not polled yet'}`,
    ]
    if (s.candidates.length === 0) lines.push('newer versions:    none known')
    for (const c of s.candidates) {
      lines.push(`newer:             ${c.version} (${c.tag}) first seen ${c.firstSeenAt.slice(0, 10)}, privacy check: ${c.check?.verdict ?? 'not run'}`)
    }
    if (s.lastUpdate) lines.push(`last update:       ${s.lastUpdate.version} at ${s.lastUpdate.at} ${s.lastUpdate.ok ? 'staged' : 'FAILED'}`)
    if (s.pending) lines.push(`pending:           ${s.pending.version} staged in ${s.pending.stageDir}; restart dsh (web UI button, or stop and start it) to switch`)
    if (s.busy) lines.push(`busy:              ${s.busy}`)
    return lines.join('\n')
  }

  // -- operations ----------------------------------------------------------
  async withBusy(label, fn) {
    if (this.busy !== undefined) throw new Error(`privacy-guard is busy (${this.busy}); try again shortly`)
    this.busy = label
    try { return await fn() } finally { this.busy = undefined }
  }

  async poll() {
    return this.withBusy('poll', async () => {
      const url = `${this.config.registryUrl.replace(/\/+$/u, '')}/${encodeURIComponent(DSH_PACKAGE)}`
      this.state.registryUrl = this.config.registryUrl
      let tags
      try {
        const response = await fetch(url, { headers: { accept: 'application/vnd.npm.install-v1+json' }, signal: AbortSignal.timeout(20_000) })
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        const doc = await response.json()
        tags = doc && typeof doc === 'object' && doc['dist-tags'] && typeof doc['dist-tags'] === 'object' ? doc['dist-tags'] : {}
      } catch (error) {
        this.state.lastPollAt = new Date().toISOString()
        this.state.lastPollError = error instanceof Error ? error.message : String(error)
        this.saveState()
        this.ctx.logger.warn(`privacy-guard: poll of ${this.registryHost()} failed: ${this.state.lastPollError}`)
        return { ok: false, error: this.state.lastPollError }
      }
      this.state.lastPollAt = new Date().toISOString()
      this.state.lastPollError = null
      this.state.distTags = Object.fromEntries(TAGS_TO_WATCH.filter((t) => typeof tags[t] === 'string').map((t) => [t, tags[t]]))
      const pinned = this.pinnedVersion()
      const discovered = []
      for (const tag of TAGS_TO_WATCH) {
        const version = this.state.distTags[tag]
        if (!version || !VERSION_RE.test(version)) continue
        if (pinned && !((compareVersions(version, pinned) ?? 0) > 0)) continue
        const existing = this.state.candidates[version]
        if (existing) { existing.tag = tag; continue }
        this.state.candidates[version] = { tag, firstSeenAt: new Date().toISOString(), check: null }
        discovered.push(version)
      }
      this.saveState()
      this.ctx.logger.info(`privacy-guard: polled ${this.registryHost()}: ${Object.entries(this.state.distTags).map(([k, v]) => `${k}=${v}`).join(' ')}${discovered.length ? `; new: ${discovered.join(', ')}` : ''}`)
      return { ok: true, distTags: this.state.distTags, discovered }
    }).then(async (result) => {
      if (result.ok && this.config.autoCheck) {
        for (const version of result.discovered) await this.check(version).catch((error) => { this.ctx.logger.warn('privacy-guard: auto check failed: %o', error) })
      }
      return result
    })
  }

  async check(version, signal) {
    if (!VERSION_RE.test(version)) return { code: 2, verdict: 'CHECK FAILED', text: `"${version}" is not a release version (expected e.g. 0.2.1-rc.2)` }
    if (!this.paths.checker) return { code: 2, verdict: 'CHECK FAILED', text: 'dsh-privacy-check.sh not found: configure privacy-guard.checkerPath' }
    if (!this.paths.baseline) return { code: 2, verdict: 'CHECK FAILED', text: 'privacy-baseline.json not found: configure privacy-guard.baselinePath' }
    return this.withBusy(`check ${version}`, async () => {
      const result = await run('bash', [this.paths.checker, version, '--baseline', this.paths.baseline, '--home', dshHome()], { timeoutMs: this.timeoutMs, signal })
      const verdict = result.code === 0 ? 'CLEAN' : result.code === 1 ? 'REVIEW NEEDED' : 'CHECK FAILED'
      const text = [
        `dsh privacy check ${version}: ${verdict} (exit ${result.code})`,
        result.stdout.trim(),
        result.code === 2 || result.error ? `stderr:\n${result.stderr.trim()}` : '',
      ].filter(Boolean).join('\n')
      const candidate = this.state.candidates[version] ?? (this.state.candidates[version] = { tag: 'manual', firstSeenAt: new Date().toISOString(), check: null })
      candidate.check = { verdict, exitCode: result.code, checkedAt: new Date().toISOString(), report: text.slice(0, 20_000) }
      this.saveState()
      return { code: result.code, verdict, text }
    })
  }

  /**
   * Stage `version` into `<installDir>.next`; refused unless its stored privacy check is CLEAN.
   * The live prefix is never touched while the Host runs: the Host serves its plugin bundles from
   * there, and replacing those files underneath an open page breaks it. The dsh wrapper swaps the
   * staged directory in on the next restart (see requestRestart and the wrapper's marker handling).
   */
  async update(version) {
    if (!VERSION_RE.test(version)) throw new Error(`"${version}" is not a release version`)
    const candidate = this.state.candidates[version]
    if (candidate?.check?.verdict !== 'CLEAN') {
      throw new Error(`refusing to pin ${version}: privacy check is ${candidate?.check?.verdict ?? 'not run'}. Run the check first; a REVIEW NEEDED result must be accepted by a human and pinned by hand.`)
    }
    return this.withBusy(`update ${version}`, async () => {
      const stageDir = `${this.paths.installDir}.next`
      await run('rm', ['-rf', stageDir], { timeoutMs: 60_000 })
      mkdirSync(stageDir, { recursive: true })
      writeFileSync(join(stageDir, 'package.json'), '{ "name": "dsh-pinned", "private": true }\n')
      const result = await run('npm', ['install', '--save-exact', '--no-fund', '--no-audit', '--loglevel=error', `${DSH_PACKAGE}@${version}`], { timeoutMs: this.timeoutMs, cwd: stageDir })
      const staged = readJson(join(stageDir, 'node_modules', DSH_PACKAGE, 'package.json'))?.version
      const ok = result.code === 0 && staged === version && existsSync(join(stageDir, 'node_modules', '.bin', 'dsh'))
      const output = `${result.stdout}\n${result.stderr}`.trim().slice(-4000)
      if (ok) {
        writeJson(this.paths.pendingFile, { version, stageDir, installDir: this.paths.installDir, stagedAt: new Date().toISOString() })
      } else {
        await run('rm', ['-rf', stageDir], { timeoutMs: 60_000 })
      }
      this.state.lastUpdate = { version, at: new Date().toISOString(), ok, output }
      this.saveState()
      this.ctx.logger[ok ? 'info' : 'warn'](`privacy-guard: update to ${version} ${ok ? `staged in ${stageDir}; restart dsh to switch` : 'FAILED'}`)
      return { ok, version, output, restartRequired: ok }
    })
  }

  /** Ask the wrapper to relaunch (swapping in a staged install when one is pending): write the marker, then stop gracefully. */
  requestRestart() {
    mkdirSync(this.paths.tools, { recursive: true })
    writeFileSync(this.paths.restartMarker, `${new Date().toISOString()}\n`)
    this.ctx.logger.info('privacy-guard: restart requested; stopping the Host so the dsh wrapper can relaunch it')
    setTimeout(() => { process.kill(process.pid, 'SIGTERM') }, 500).unref()
  }
}

// ---------------------------------------------------------------- plugin

const USAGE = [
  'Usage:',
  '  /dsh-privacy                   status: pinned, installed, baseline, polling, known newer versions',
  '  /dsh-privacy poll              ask the registry now and privacy-check any newer version',
  '  /dsh-privacy check <version>   compare a published release against the audited baseline',
  '  /dsh-privacy update <version>  pin a version whose check is CLEAN (restart dsh afterwards)',
].join('\n')

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {object} config
 */
export function apply(ctx, config) {
  const guard = new Guard(ctx, config)
  guard.installedVersionAtBoot = guard.installedVersion()
  const timeoutMs = guard.timeoutMs

  // -- polling -------------------------------------------------------------
  const hours = config.checkIntervalHours ?? 24
  if (hours > 0) {
    const intervalMs = Math.min(hours * 3_600_000, 2_147_000_000)
    const due = () => guard.state.lastPollAt === null || Date.now() - Date.parse(guard.state.lastPollAt) >= intervalMs
    ctx.setTimeout(() => { if (due()) void guard.poll().catch(() => {}) }, 15_000)
    ctx.setInterval(() => { if (due()) void guard.poll().catch(() => {}) }, Math.min(intervalMs, 3_600_000))
  }

  // -- slash command -------------------------------------------------------
  ctx.commands.register({
    definitionId: CommandDefinitionId('dsh-privacy-guard'),
    name: 'dsh-privacy',
    description: 'Privacy status of this dsh install, poll for releases, check or pin a version',
    input: { hint: 'status | poll | check <version> | update <version>' },
    async handler(invocation) {
      const [verb, arg] = invocation.rawInput.trim().split(/\s+/u).filter(Boolean)
      try {
        if (verb === undefined || verb === 'status') return { kind: 'success', text: guard.statusText() }
        if (verb === 'help') return { kind: 'success', text: USAGE }
        if (verb === 'poll') { const r = await guard.poll(); return { kind: r.ok ? 'success' : 'error', text: r.ok ? guard.statusText() : `poll failed: ${r.error}` } }
        if (verb === 'update') {
          if (!arg) return { kind: 'error', text: USAGE }
          const r = await guard.update(arg)
          return { kind: r.ok ? 'success' : 'error', text: r.ok ? `Staged ${arg}. Restart dsh to switch to it (the web UI offers a Restart button; or stop and start dsh).` : `update failed:\n${r.output}` }
        }
        const version = verb === 'check' ? arg : VERSION_RE.test(verb) ? verb : undefined
        if (version === undefined) return { kind: 'error', text: `Unknown input "${invocation.rawInput.trim()}".\n${USAGE}` }
        const result = await guard.check(version)
        return result.code === 2 ? { kind: 'error', text: result.text } : { kind: 'success', text: result.text }
      } catch (error) {
        return { kind: 'error', text: error instanceof Error ? error.message : String(error) }
      }
    },
  })

  // -- tools ---------------------------------------------------------------
  ctx.tools.register(defineTool({
    name: 'dsh_privacy_status',
    description: 'Report the pinned, installed, running, baseline and npm-published versions of DeepSeek Harness (dsh) on this machine, the registry polling state, and every newer version found with its stored privacy-check verdict. Read-only.',
    parameters: {},
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    isConcurrencySafe: () => true,
    async execute() { return guard.statusText() },
  }))

  ctx.tools.register(defineTool({
    name: 'dsh_privacy_check',
    description: 'Compare a published @deepseek-ai/dsh release against the audited privacy baseline before pinning it. '
      + 'Downloads the release bundle tarballs to a temp dir (read-only for the installation) and reports CLEAN, '
      + 'REVIEW NEEDED with FAIL/WARN/INFO findings, or CHECK FAILED. Never pins anything.',
    parameters: {
      version: { type: 'string', required: true, description: 'Exact published version, e.g. 0.2.1-rc.2' },
    },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    timeoutMs,
    isConcurrencySafe: () => false,
    async execute(args, exec) {
      try { return (await guard.check(args.version, exec?.signal)).text } catch (error) { return `CHECK FAILED: ${error instanceof Error ? error.message : String(error)}` }
    },
  }))

  // -- skill ---------------------------------------------------------------
  let skillBody
  try { skillBody = readFileSync(join(PKG_DIR, 'SKILL.md'), 'utf8') } catch (error) {
    ctx.logger.warn('privacy-guard: SKILL.md missing, skill not registered: %o', error)
  }
  if (skillBody !== undefined) {
    ctx.skills.register({
      name: 'dsh-update',
      description: 'Upgrade the pinned dsh install only after the release passes the privacy check against the audited baseline. Use when asked to update, upgrade, bump, or pin a new dsh version, or whether a new dsh release is safe.',
      content: skillBody.replace(/^---[\s\S]*?\n---\n/u, ''),
      source: 'runtime',
      resourceBase: { kind: 'directory', path: PKG_DIR },
    })
  }

  // -- authenticated HTTP routes for the browser half (web profile only) ----
  ctx.inject(['connection'], (child) => {
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } })
    const failure = (error) => json(409, { ok: false, error: error instanceof Error ? error.message : String(error) })
    const readBody = async (request) => { try { return await request.json() } catch { return {} } }
    const route = (path, methods, fetchFn) => child.connection.fetch.register({ path: `/api/privacy-guard/${path}`, methods, requestBody: 'buffered', fetch: fetchFn })
    route('status', ['GET'], async () => json(200, { ok: true, status: guard.status() }))
    route('poll', ['POST'], async () => { try { const r = await guard.poll(); return json(200, { ...r, status: guard.status() }) } catch (error) { return failure(error) } })
    route('check', ['POST'], async (request) => {
      const { version } = await readBody(request)
      if (typeof version !== 'string') return json(400, { ok: false, error: 'version required' })
      try { const r = await guard.check(version); return json(200, { ok: r.code !== 2, ...r, status: guard.status() }) } catch (error) { return failure(error) }
    })
    route('update', ['POST'], async (request) => {
      const { version } = await readBody(request)
      if (typeof version !== 'string') return json(400, { ok: false, error: 'version required' })
      try { const r = await guard.update(version); return json(200, { ...r, status: guard.status() }) } catch (error) { return failure(error) }
    })
    route('restart', ['POST'], async () => { guard.requestRestart(); return json(200, { ok: true }) })
    child.logger.info('privacy-guard: web routes registered under /api/privacy-guard/')
  })

  ctx.logger.info(`privacy-guard ready: checker=${guard.paths.checker ?? 'missing'} baseline=${guard.paths.baseline ?? 'missing'} polling=${hours > 0 ? `${hours}h` : 'off'}`)
}
