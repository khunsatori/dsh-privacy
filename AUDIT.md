# Audit: outbound data paths in DeepSeek Harness

Scope: the published `@deepseek-ai/dsh` release 0.2.1-rc.2 (git `687f282`, 2026-10-17) and the npm `latest` 0.2.0-rc.2, read from source on 2026-10-18. Method: full-text search of the source tree for telemetry vendors, hardcoded hosts, and upload paths; reading of every plugin that opens a network connection; the design notes under `.agents/notes` that record why each default is what it is; and a socket capture of a live headless session after the fix.

## Default-on paths

| # | Plugin row | Default | What it sends | Where |
|---|---|---|---|---|
| 1 | `session-log-deepseek` | on | The complete session event log since the last accepted watermark, up to 8 MiB per request: user and assistant messages, every tool result (file contents, command output), the working directory, and events the model no longer sees after compaction. Attached as the `dsh_session_log` field of every request made through the DeepSeek adapter, whatever base URL it points at. | the configured DeepSeek endpoint |
| 2 | `plugin-package-inventory-deepseek` | on | Names and versions of every active plugin, as `dsh_plugin_packages` on each DeepSeek request. | same |
| 3 | `session-telemetry-otel` | `FEEDBACK_ONLY` | Nothing in ordinary use. Any feedback action releases the whole session history from event zero, tagged with a persistent random UUID stored in `~/.dsh/.anonymous-user-id`. Feedback actions include `/feedback`, the Dislike dialog, and a plain Thumbs-up click; only the Dislike dialog shows a disclosure. No redaction rules ship. Provider-independent: it fires with any model provider. | `dsh-otel-collector.deepseeksvc.com` |
| 4 | `product-analytics` + `desktop-product-telemetry` | on, desktop profile only | App launch, button clicks, model and effort switches, OS version and build, CPU model, core counts, memory, account device and user id. | same collector |
| 5 | electron-updater + policy endpoint | on, desktop app only | Every 10 minutes: client version, platform, architecture, locale, timezone offset, update channel, bundled runtime version. No in-app switch. | `download.deepseek.com`, a packaging-time policy origin |

Paths 1 and 2 depend on the DeepSeek adapter, not the hostname. Path 3 is provider-independent. Paths 4 and 5 exist only in the desktop app, which this repo does not install.

## What is clean

- No PostHog, Sentry, Mixpanel, Segment or similar. The only telemetry dependency is the OpenTelemetry SDK used by paths 3 and 4.
- No heartbeat, install beacon or update check in the CLI or web profiles.
- Crash reports are written to a local file only.
- Account sign-in to `platform.deepseek.com` and the DeepSeek web-search tool only run when the user, or the model on the user's behalf, invokes them. Both are disabled here.
- The model and provider catalog is bundled at build time; nothing is fetched from models.dev or similar at runtime.

## What this repo changes

`~/.dsh/cordis.patch.yml`, applied after every profile patch so the Web UI cannot undo it:

```yaml
- id: session-telemetry-otel
  disabled: true
- id: session-log-deepseek
  config: { enabled: false }
- id: plugin-package-inventory-deepseek
  config: { enabled: false }
- id: llm-deepseek
  disabled: true
- id: llm-deepseek-account
  disabled: true
- id: web-search-deepseek
  disabled: true
- id: web-deepseek-api
  disabled: true
```

The wrapper additionally sets `DSH_TELEMETRY_MODE=DISABLED` and `DSH_TELEMETRY_DISABLED=1`. These cannot go in `~/.dsh/.env` because dsh rejects `DSH_*` names there.

## Verification

- `dsh --profile web --dump-config` shows every lock after install; the installer checks the five decisive rows.
- One headless prompt through Neuralwatt while sampling every socket of the process tree every 300 ms: the only remote endpoint was port 443 on an `api.neuralwatt.com` address. A connection shorter than the sampling interval could hide from that method; a packet capture is the only complete check.
- The one-click update flow was clicked through in a browser on a throwaway install from 0.2.0-rc.2 to 0.2.1-rc.2.

## Why the checker exists

The telemetry default moved from on (July 2026) to off (August 10) to feedback-gated (August 25), per the project's own design notes. A future release can move it again, rename the rows the patch targets so the overrides silently stop applying, or add a new upload path. `dsh-privacy-check.sh` compares a release's bundle configuration against `privacy-baseline.json` and fails on any of those. It reads the npm tarballs only and executes nothing from them.
