# dsh-privacy-guard

A DeepSeek Harness bundle that turns the privacy-checked upgrade procedure into native harness surfaces, including a one-click update in the web UI.

| Surface | Name | What it does |
|---|---|---|
| Registry poll | every `checkIntervalHours` | One GET of the abbreviated npm metadata for `@deepseek-ai/dsh`; newer `latest`/`next` versions are privacy-checked automatically and remembered in `$DSH_HOME/tools/update-state.json`. |
| Web UI | sidebar footer button + card | "Update to x.y.z" appears only for a version whose check is CLEAN. Install runs `npm install --save-exact` in the private prefix; Restart stops the Host and the `dsh` wrapper relaunches it on the new version. A REVIEW NEEDED version shows its findings instead of an install button. |
| Slash command | `/dsh-privacy [status \| poll \| check <v> \| update <v>]` | Same operations from the composer, no model turn. |
| Tools | `dsh_privacy_status`, `dsh_privacy_check` | Same status and check for the agent. Read-only. |
| Skill | `dsh-update` | The agent-driven upgrade procedure: status, check, interpret, pin with approval, verify. |
| HTTP | `GET/POST /api/privacy-guard/{status,poll,check,update,restart}` | What the web UI calls. Behind the harness's own browser authentication (signed cookie, loopback/trusted-host fence); only the owner Peer reaches these routes. |

`update` refuses any version whose stored privacy check is not CLEAN. A REVIEW NEEDED release has to be read by a human and pinned by hand; the plugin never bypasses that.

## What leaves the machine

One poll is a single `GET https://registry.npmjs.org/@deepseek-ai%2Fdsh` with `Accept: application/vnd.npm.install-v1+json` and Node's default User-Agent. No npm CLI, no account, nothing about this machine beyond its IP. A privacy check or an install additionally runs `npm pack` / `npm install` against the same registry. Nothing is ever sent to DeepSeek's own hosts; the DeepSeek API routes stay disabled by the home patch.

## Install

`install-dsh-clean.sh` copies this package to `$DSH_HOME/plugins/dsh-privacy-guard` and adds it to the web and headless profiles:

```bash
dsh plugin --profile web add ~/.dsh/plugins/dsh-privacy-guard
```

Remove with `dsh plugin --profile web remove dsh-privacy-guard`. The browser half (`client.js`) is hand-written in the loader's factory format, so there is no build step.

## Configuration

Row id `privacy-guard`. All fields optional:

| Key | Default |
|---|---|
| `checkIntervalHours` | `24` (0 disables polling) |
| `registryUrl` | `https://registry.npmjs.org` |
| `autoCheck` | `true` |
| `checkerPath` | `$DSH_HOME/tools/dsh-privacy-check.sh`, else the packaged `scripts/` copy |
| `baselinePath` | `$DSH_HOME/tools/privacy-baseline.json`, else the packaged copy |
| `installDir` | `~/.dsh-cli` |
| `timeoutMs` | `300000` |

A profile patch override replaces the whole `config` object, so restate `checkIntervalHours` when overriding another key.

## Update and restart mechanics

The live install prefix is never modified while dsh runs: the Host serves its plugin bundles from it, and replacing those files under an open page breaks the page. `POST /update` therefore runs `npm install` into a sibling directory `<installDir>.next` and writes `$DSH_HOME/tools/pending-install.json`. `POST /restart` writes `$DSH_HOME/tools/restart-requested` and sends SIGTERM to the Host, which exits 0 after a graceful shutdown. The `dsh` wrapper written by the installer runs dsh in a loop: when the marker exists it moves the current prefix to `<installDir>.prev`, moves `.next` into place, records the pinned version, and relaunches. An ordinary Ctrl-C or crash still exits. A staged install is also swapped in on the next manual start. The browser polls `/api/privacy-guard/status` and reloads itself once the new Host answers. To roll back, stop dsh, swap `.prev` back by hand, and restart.
