# dsh-privacy

A zero-telemetry install of [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) for macOS, with [Neuralwatt](https://neuralwatt.com) as the only model provider and a privacy-checked updater built in.

DeepSeek Harness is a good open-source agent harness, but as shipped it sends more than the model request: the full session log rides along on every DeepSeek API call, an installed-plugin inventory does too, and any thumbs-up or `/feedback` uploads the whole session to a DeepSeek OpenTelemetry collector. [AUDIT.md](AUDIT.md) lists what was found. This repo turns all of that off, points the harness at an OpenAI-compatible provider, pins the audited release, and makes sure a later release cannot quietly turn it back on.

## Install

Requirements: macOS, `curl`. Node 22+ is installed through nvm if missing (you are asked first). A Neuralwatt API key from <https://portal.neuralwatt.com>.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/khunsatori/dsh-privacy/v1.0.1/install.sh)"
```

You are prompted for the API key (input hidden). To run unattended:

```bash
NEURALWATT_API_KEY=sk-... DSH_AUTO_INSTALL_NODE=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/khunsatori/dsh-privacy/v1.0.1/install.sh)"
```

Then:

```bash
dsh web
```

The Web UI opens at `http://127.0.0.1:3080`. Prefer reading scripts before running them? Clone the repo and run `./install-dsh-clean.sh`; the one-liner does nothing more than download a snapshot of this repo and run that file.

### What the installer does

1. Runs the privacy check on the release it is about to pin and stops if anything changed since the audit.
2. Writes `~/.dsh/cordis.patch.yml`, a home-level patch that wins over every profile: session-log upload off, plugin-inventory upload off, OpenTelemetry feedback upload disabled, and all DeepSeek API routes disabled.
3. Writes the Neuralwatt provider into the `web` and `headless` profiles with eleven models declared from Neuralwatt's published specs (`deepseek-v4.1-flash` is the default).
4. Stores the key in `~/.dsh/.env` with mode 600.
5. Installs the pinned `@deepseek-ai/dsh` into a private npm prefix, `~/.dsh-cli`, never globally.
6. Writes a `~/.local/bin/dsh` wrapper that pins the Node binary and hard-sets the telemetry opt-out environment as a second lock.
7. Installs the `dsh-privacy-guard` plugin into both profiles and verifies the composed configuration shows every lock.

Nothing in `~/.dsh` is overwritten on a re-run; existing patches and the key are left alone. Tunables are documented at the top of [install-dsh-clean.sh](install-dsh-clean.sh).

## Updating

Upstream changed its telemetry defaults three times in three months, so updating blindly is the risk. The bundled `dsh-privacy-guard` plugin handles it:

- While `dsh web` runs, once a day the Host fetches the npm metadata for `@deepseek-ai/dsh` and compares the `latest` and `next` tags with your pin. Each newer version is checked against the audited baseline automatically: bundle configuration rows, hostnames, environment switches, dependency names, and whether your own overrides still target rows that exist. The headless profile never polls on its own; `/dsh-privacy poll` works there too.
- A release that passes shows **Update to x.y.z** in the sidebar footer. **Install** downloads it into `~/.dsh-cli.next`, next to the running install, never underneath it. **Restart** asks once (it interrupts any running session), then stops the Host; the wrapper swaps the directories, keeps the old one at `~/.dsh-cli.prev`, and relaunches.
- A release that changed something shows **x.y.z needs review** and the findings. The plugin never installs those; read the diff, decide, and pin by hand if you accept it.
- The plugin declares the dsh range it was written for (`engines.dsh` in `dsh-privacy-guard/package.json`, currently `>=0.2.0 <0.3.0`). A release outside that range shows **x.y.z needs a newer plugin** instead of an Update button, even when its privacy check is CLEAN, and `/dsh-privacy update` refuses it: dsh disables a plugin whose range it does not satisfy, and you would lose the guard on the new version. Update the plugin first (stop dsh, pull this repo, re-run the installer with `DSH_ALLOW_EXISTING_HOME=1`), then update dsh.
- The same works from the composer: `/dsh-privacy`, `/dsh-privacy check <version>`, `/dsh-privacy update <version>`. The agent gets `dsh_privacy_status` and `dsh_privacy_check` tools and a `dsh-update` skill with the full procedure.

Manual check of any release:

```bash
~/.dsh/tools/dsh-privacy-check.sh 0.2.2 --baseline ~/.dsh/tools/privacy-baseline.json --home ~/.dsh
```

Exit 0 is CLEAN, 1 needs review, 2 means the tool failed. The baseline is the audited release; refresh it only after a human review with `--write-baseline`.

## What leaves your machine

| When | Destination | What |
|---|---|---|
| Every prompt | `api.neuralwatt.com` | The model request |
| Once a day, while `dsh web` runs | `registry.npmjs.org` | One GET of the package metadata, Node's default User-Agent, nothing else |
| Install, check, update | `registry.npmjs.org` | npm downloads |
| Web search tool, if the model uses it | the provider you configure | Disabled for DeepSeek by default |

Nothing goes to DeepSeek's hosts. Verified with a socket capture of a live session and a browser click-through of the update flow; see [AUDIT.md](AUDIT.md) for the method and the caveats.

## Claude Code

The repo ships a Claude Code skill at [.claude/skills/dsh-update/SKILL.md](.claude/skills/dsh-update/SKILL.md). Open this repo in Claude Code and `/dsh-update` runs the same check-then-pin procedure from outside dsh.

## Uninstall

```bash
rm -rf ~/.dsh ~/.dsh-cli ~/.dsh-cli.next ~/.dsh-cli.prev ~/.local/bin/dsh
```

`~/.dsh` holds your sessions and key; back it up first if you want them.

## Layout

| Path | Role |
|---|---|
| `install.sh` | One-line bootstrap: downloads a snapshot of this repo and runs the installer |
| `install-dsh-clean.sh` | The installer |
| `dsh-privacy-check.sh` | Release checker, compares npm tarballs against the baseline |
| `privacy-baseline.json` | Audited baseline (dsh 0.2.1-rc.2) |
| `dsh-privacy-guard/` | The dsh plugin: polling, web UI, command, tools, skill |
| `AUDIT.md` | What the audit found |

## Caveats

- The checker reads bundle configuration, hostnames and dependency names. It does not diff plugin source, so a plugin already in the baseline could change behaviour internally. Release notes and a packet capture remain worth a look on major upgrades.
- Only the `web` and `headless` profiles are configured. The desktop app has its own updater and analytics and is not covered; stay on `dsh web`.
- The plugin's browser half, `dsh-privacy-guard/client.js`, is hand-written in the shape the web client's module loader expects: one `window.__ModuleLoader__.load({ id, factory })` registration whose factory receives `require` and returns the plugin's exports, the same shape dsh's own build emits for client bundles. That shape is an internal contract of the harness, not a public API, and the privacy checker does not watch it. If a release changes it, the web client's boot audit reports `dsh-privacy-guard: import failed` and keeps the page on the boot screen until the plugin is updated or removed from the web profile (`dsh plugin --profile web remove dsh-privacy-guard`). The Host half, the headless profile and the privacy locks (the home patch and the wrapper's environment) are not affected. The `engines.dsh` range above is the fence against a surprise of that kind: on a release outside it, dsh disables the plugin instead of loading it.
- The one-liner and the bootstrap it fetches are pinned to the `v1.0.1` tag, so the snapshot you install is the reviewed one. To track `main` instead, fetch `.../main/install.sh` and set `DSH_PRIVACY_REF=main`; any tag or commit SHA works there too.

## CI

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on every push: shellcheck on the three scripts, a syntax check of both plugin halves, the privacy check of the audited release against its baseline (must be CLEAN), and the installer into throwaway directories followed by a read-back of the composed web profile.

## License

Apache-2.0. DeepSeek Harness itself is MIT, by DeepSeek AI.
