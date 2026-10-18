/* dsh-privacy-guard browser half. Hand-written in the harness loader's lazy-CJS factory format
 * (the same shape tsdown emits for built-in client plugins), so the package needs no build step.
 * Talks to the Host through the authenticated exact routes under /api/privacy-guard/. */
window.__ModuleLoader__.load({
  id: 'dsh-privacy-guard',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })
    const React = require('react')
    const { jsx, jsxs } = require('react/jsx-runtime')
    const { createSnapshotStore } = require('@deepseek-ai/dsh-client-store')
    const { Button } = require('@deepseek-ai/dsh-client-ui-primitives')

    const STATUS_POLL_MS = 10 * 60 * 1000
    const DISMISS_KEY = 'dsh-privacy-guard.dismissed'

    // ---------------------------------------------------------------- Host calls
    function api(path, init) {
      const url = new URL(`api/privacy-guard/${path}`, document.baseURI)
      return fetch(url, { credentials: 'include', ...init })
    }
    async function call(path, body) {
      const init = body === undefined
        ? { method: 'GET' }
        : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }
      const response = await api(path, init)
      let data = {}
      try { data = await response.json() } catch (_error) { /* non-JSON failure body */ }
      if (!response.ok && data.error === undefined) data = { ok: false, error: `HTTP ${response.status}` }
      return data
    }

    // ---------------------------------------------------------------- controller
    class GuardController {
      constructor() {
        this.store = createSnapshotStore({
          status: null,            // last Host status object
          phase: 'idle',           // idle | working | updated | restarting | error
          message: null,           // human line for the card
          detail: null,            // long text (check report / npm output)
          cardOpen: false,
          confirmRestart: false,   // the Restart button asks once before POST /restart
          dismissed: sessionStorage.getItem(DISMISS_KEY),
        })
        this.timer = undefined
        this.disposed = false
      }
      update(fn) { this.store.update(fn) }
      get snapshot() { return this.store.getSnapshot() }

      start() {
        void this.refresh()
        this.timer = setInterval(() => { void this.refresh() }, STATUS_POLL_MS)
      }
      dispose() { this.disposed = true; if (this.timer !== undefined) clearInterval(this.timer) }

      async refresh() {
        try {
          const data = await call('status')
          if (this.disposed) return
          if (data.ok) this.update((s) => { s.status = data.status })
        } catch (_error) { /* Host away; keep the last status */ }
      }

      /**
       * The newest version worth showing: installable (CLEAN and inside this plugin's dsh range) first,
       * else REVIEW NEEDED, else unchecked, and last anything outside the plugin's engines.dsh range,
       * which dsh would disable the plugin on (the Host reports it as pluginCompatible: false).
       */
      candidate() {
        const status = this.snapshot.status
        if (!status || !Array.isArray(status.candidates) || status.candidates.length === 0) return undefined
        const rank = (c) => (c.pluginCompatible === false ? 3 : c.check?.verdict === 'CLEAN' ? 0 : c.check?.verdict === 'REVIEW NEEDED' ? 1 : 2)
        return [...status.candidates].sort((a, b) => rank(a) - rank(b))[0]
      }

      async poll() {
        this.update((s) => { s.phase = 'working'; s.message = 'Checking the registry…'; s.detail = null; s.cardOpen = true })
        const data = await call('poll', {})
        this.update((s) => {
          if (data.status) s.status = data.status
          s.phase = data.ok ? 'idle' : 'error'
          s.message = data.ok ? (s.status && s.status.candidates.length ? 'Newer release found.' : 'You are on the newest release.') : `Poll failed: ${data.error}`
        })
      }

      async check(version) {
        this.update((s) => { s.phase = 'working'; s.message = `Running the privacy check for ${version}…`; s.detail = null; s.cardOpen = true })
        const data = await call('check', { version })
        this.update((s) => {
          if (data.status) s.status = data.status
          s.phase = data.ok ? 'idle' : 'error'
          s.message = data.verdict ? `${version}: ${data.verdict}` : `Check failed: ${data.error}`
          s.detail = data.text ?? null
        })
      }

      async updateTo(version) {
        this.update((s) => { s.phase = 'working'; s.message = `Installing ${version}… (npm install, about a minute)`; s.detail = null; s.cardOpen = true })
        const data = await call('update', { version })
        this.update((s) => {
          if (data.status) s.status = data.status
          s.phase = data.ok ? 'updated' : 'error'
          s.message = data.ok ? `${version} is downloaded and staged. Restart dsh to switch to it.` : `Update refused: ${data.error ?? 'npm install failed'}`
          s.detail = data.output ?? null
        })
      }

      askRestart() { this.update((s) => { s.confirmRestart = true; s.cardOpen = true }) }
      cancelRestart() { this.update((s) => { s.confirmRestart = false }) }

      /** Only the Confirm button of the restart prompt calls this; it is the one path to POST /restart. */
      async restart() {
        this.update((s) => { s.confirmRestart = false; s.phase = 'restarting'; s.message = 'Restarting dsh… this page reloads when the Host is back.'; s.cardOpen = true })
        try { await call('restart', {}) } catch (_error) { /* the Host may close before answering */ }
        const started = Date.now()
        const probe = async () => {
          if (this.disposed) return
          try {
            const response = await api('status', { method: 'GET', cache: 'no-store' })
            if (response.ok) { location.reload(); return }
          } catch (_error) { /* still down */ }
          if (Date.now() - started < 120_000) setTimeout(probe, 2000)
          else this.update((s) => { s.phase = 'error'; s.message = 'The Host did not come back within two minutes. Start it by hand with: dsh web' })
        }
        setTimeout(probe, 4000)
      }

      dismiss(version) {
        sessionStorage.setItem(DISMISS_KEY, version)
        this.update((s) => { s.dismissed = version; s.cardOpen = false })
      }
      openCard() { this.update((s) => { s.cardOpen = true }) }
      closeCard() { this.update((s) => { s.cardOpen = false; s.confirmRestart = false; if (s.phase === 'error') s.phase = 'idle' }) }
    }

    // ---------------------------------------------------------------- components
    const card = {
      position: 'fixed', right: 16, bottom: 16, zIndex: 1050, width: 380, maxWidth: 'calc(100vw - 32px)',
      padding: '14px 16px', borderRadius: 12, background: 'var(--dsh-surface-elevated, var(--color-bg-elevated, #1f1f1f))',
      color: 'var(--dsh-text, inherit)', boxShadow: '0 8px 30px rgba(0,0,0,.35)', border: '1px solid rgba(127,127,127,.25)',
      font: 'inherit', fontSize: 13, lineHeight: 1.45,
    }
    const pre = { margin: '10px 0 0', maxHeight: 220, overflow: 'auto', whiteSpace: 'pre-wrap', fontSize: 11, opacity: .85 }
    const row = { display: 'flex', gap: 8, marginTop: 12, flexWrap: 'wrap' }

    function FooterAction({ useGuard, controller, wide }) {
      const status = useGuard((s) => s.status)
      const phase = useGuard((s) => s.phase)
      const dismissed = useGuard((s) => s.dismissed)
      const candidate = controller.candidate()
      const restartPending = status?.restartPending === true || phase === 'updated'
      if (!restartPending && (!candidate || candidate.version === dismissed)) return null
      const label = restartPending ? 'Restart to finish update'
        : candidate.pluginCompatible === false ? `${candidate.version} needs a newer plugin`
          : candidate.check?.verdict === 'CLEAN' ? `Update to ${candidate.version}`
            : candidate.check?.verdict === 'REVIEW NEEDED' ? `${candidate.version} needs review`
              : `Check ${candidate.version}`
      return jsx(Button, {
        size: 'sm', variant: 'ghost', title: label, 'data-privacy-guard': 'footer-action',
        onClick: () => { controller.openCard() },
        children: wide ? label : '⬆',
      })
    }

    function Card({ useGuard, controller }) {
      const open = useGuard((s) => s.cardOpen)
      const phase = useGuard((s) => s.phase)
      const message = useGuard((s) => s.message)
      const detail = useGuard((s) => s.detail)
      const status = useGuard((s) => s.status)
      const confirmRestart = useGuard((s) => s.confirmRestart)
      if (!open) return null
      const candidate = controller.candidate()
      const working = phase === 'working' || phase === 'restarting'
      const restartPending = status?.restartPending === true || phase === 'updated'
      // Outside this plugin's engines.dsh range: dsh would disable the plugin on that version, so no
      // Install (and no point checking); the Host's `update` refuses it as well.
      const incompatible = candidate !== undefined && candidate.pluginCompatible === false
      const buttons = []
      if (!working && !confirmRestart) {
        if (restartPending) buttons.push(jsx(Button, { size: 'sm', variant: 'primary', onClick: () => controller.askRestart(), children: 'Restart dsh now' }, 'restart'))
        else if (candidate && !incompatible && candidate.check?.verdict === 'CLEAN') buttons.push(jsx(Button, { size: 'sm', variant: 'primary', onClick: () => controller.updateTo(candidate.version), children: `Install ${candidate.version}` }, 'update'))
        else if (candidate && !incompatible && candidate.check?.verdict !== 'REVIEW NEEDED') buttons.push(jsx(Button, { size: 'sm', variant: 'primary', onClick: () => controller.check(candidate.version), children: `Run privacy check for ${candidate.version}` }, 'check'))
        if (candidate && candidate.check?.verdict === 'REVIEW NEEDED') buttons.push(jsx(Button, { size: 'sm', onClick: () => controller.update((s) => { s.detail = candidate.check.report }), children: 'Show findings' }, 'show'))
        buttons.push(jsx(Button, { size: 'sm', onClick: () => controller.poll(), children: 'Check for updates' }, 'poll'))
        if (candidate && !restartPending) buttons.push(jsx(Button, { size: 'sm', onClick: () => controller.dismiss(candidate.version), children: 'Dismiss' }, 'dismiss'))
        buttons.push(jsx(Button, { size: 'sm', onClick: () => controller.closeCard(), children: 'Close' }, 'close'))
      }
      const supports = status?.plugin?.requiresDsh ?? '?'
      const headline = message ?? (candidate
        ? (incompatible
          ? `dsh ${candidate.version} (${candidate.tag}) needs a newer dsh-privacy-guard: this one supports dsh ${supports}${candidate.check?.verdict === 'CLEAN' ? ', although the release passed the privacy check' : ''}. Installing it now would make dsh disable the plugin.`
          : candidate.check?.verdict === 'CLEAN'
            ? `dsh ${candidate.version} (${candidate.tag}) passed the privacy check. You are on ${status?.installed ?? '?'}.`
            : candidate.check?.verdict === 'REVIEW NEEDED'
              ? `dsh ${candidate.version} changed its privacy defaults. Review before installing.`
              : `dsh ${candidate.version} is published but not yet checked.`)
        : 'DeepSeek Harness updates')
      return jsxs('div', { style: card, role: 'dialog', 'aria-label': 'DeepSeek Harness updates', 'data-privacy-guard': 'card', children: [
        jsx('div', { style: { fontWeight: 600, marginBottom: 4 }, children: 'DeepSeek Harness update' }),
        jsx('div', { children: headline }),
        status ? jsx('div', { style: { opacity: .7, marginTop: 4, fontSize: 12 }, children:
          `installed ${status.installed ?? '?'} · baseline ${status.baseline ?? '?'} · plugin ${status.plugin?.version ?? '?'} for dsh ${supports} · polls ${status.polling?.registry ?? '?'} every ${status.polling?.intervalHours ?? '?'}h` }) : null,
        detail ? jsx('pre', { style: pre, children: detail }) : null,
        confirmRestart ? jsxs('div', { 'data-privacy-guard': 'restart-confirm', children: [
          jsx('div', { style: { marginTop: 10 }, children: 'Restart interrupts any running session. Continue?' }),
          jsxs('div', { style: row, children: [
            jsx(Button, { size: 'sm', variant: 'primary', onClick: () => controller.restart(), children: 'Confirm' }, 'confirm'),
            jsx(Button, { size: 'sm', onClick: () => controller.cancelRestart(), children: 'Cancel' }, 'cancel'),
          ] }),
        ] }) : null,
        buttons.length ? jsx('div', { style: row, children: buttons }) : null,
      ] })
    }

    // ---------------------------------------------------------------- plugin
    exports.inject = ['slots']
    exports.apply = function apply(ctx) {
      const controller = new GuardController()
      const face = () => ({ hooks: { guard: controller.store }, controller })
      ctx.effect(() => { controller.start(); return () => { controller.dispose() } })
      ctx.slots.inject('sidebar.footer.action', () => ctx.slots.register({
        name: 'sidebar.footer.action', id: 'dsh-privacy-guard', order: 50, inject: face,
      }, FooterAction))
      ctx.slots.inject('shell.overlay', () => ctx.slots.register({
        name: 'shell.overlay', id: 'dsh-privacy-guard-card', inject: face,
      }, Card))
    }
    return module.exports
  },
})
