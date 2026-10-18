---
name: dsh-update
description: Upgrade the pinned DeepSeek Harness (dsh) install only after verifying that the release's privacy defaults (telemetry, session-log upload, plugin inventory, DeepSeek routes, new hostnames) have not changed relative to the audited baseline. Use when the user asks to update, upgrade, bump, or pin a new dsh version, or asks whether a new dsh release is safe to install.
---

# dsh-update

Upgrade `@deepseek-ai/dsh` to a newer pinned version, but only after `./dsh-privacy-check.sh` confirms the release's default-on data paths match the audited baseline. Never pin a version the checker has not passed, and never bypass a FAIL without the user explicitly accepting each finding.

## Context you need

- The same procedure is installed inside dsh itself as the `dsh-privacy-guard` bundle (source in `dsh-privacy-guard/`): the `/dsh-privacy` slash command, the `dsh_privacy_status` and `dsh_privacy_check` tools, and a `dsh-update` skill the dsh agent can load. This Claude Code skill drives the identical checker from outside dsh.
- The checker and baseline live at the root of this repo: `./dsh-privacy-check.sh` and `./privacy-baseline.json`. The installer also copied them to `$DSH_HOME/tools/` (default `~/.dsh/tools/`) together with `pinned-version`.
- The CLI is installed in a private npm prefix, default `~/.dsh-cli`, and invoked through the wrapper `~/.local/bin/dsh`. The pinned version is the exact version in `~/.dsh-cli/package.json`.
- Local overrides live in `$DSH_HOME/cordis.patch.yml` (privacy locks, home layer wins) and `$DSH_HOME/profiles/web/cordis.patch.yml` (Neuralwatt provider, default model).
- The baseline was recorded from release `0.2.1-rc.2`, audited on 2026-10-18. Audit findings are summarised at the top of `install-dsh-clean.sh`.

## Procedure

1. **Find current and candidate versions.**
   ```bash
   cat ~/.dsh/tools/pinned-version 2>/dev/null; node -p 'require(process.env.HOME+"/.dsh-cli/package.json").dependencies["@deepseek-ai/dsh"]'
   npm view @deepseek-ai/dsh dist-tags --json
   npm view @deepseek-ai/dsh versions --json | tail -15
   ```
   If the user named a version, use it. Otherwise propose the newest version on the `latest` tag, and mention `next` separately. Note that `latest` can lag `next` by a minor release.

2. **Run the privacy check against the candidate.**
   ```bash
   ./dsh-privacy-check.sh <candidate> --baseline ./privacy-baseline.json --home ~/.dsh
   ```
   Exit 0 means CLEAN, 1 means REVIEW, 2 means the tool itself failed (network, unknown version).

3. **Interpret the result.**
   - **CLEAN**: go to step 4.
   - **REVIEW with only `row-new`/`dep-new` WARN or INFO lines**: list them to the user in plain words. For each new row or dependency whose name is not obviously inert, fetch the package README from the npm tarball (`npm pack @deepseek-ai/<pkg>@<ver>` then read `package/README.md`) and state whether it opens a network path. Ask the user before continuing.
   - **REVIEW with FAIL lines**: stop. Show the user the diff the checker printed for each changed watched row, each new hostname, and each orphaned override. Explain in one sentence per finding what data it would send and where. Do not pin unless the user says so for each finding. If an override is orphaned (`override-orphaned`), the fix is usually a renamed row id: find the new id in the tarball's `cordis.patch.yml` and update the local patch before pinning.

4. **Pin the new version.** Prefer the staged path the dsh-privacy-guard plugin provides (the web UI's Update button, or `/dsh-privacy update <candidate>` in the composer): it downloads into `~/.dsh-cli.next` and the wrapper swaps it in on restart, so a running `dsh web` is never modified underneath. Only when dsh is NOT running, pin by hand:
   ```bash
   pgrep -fl '.dsh-cli/node_modules/.bin/dsh' && echo "dsh is running: stop it first" || ( cd ~/.dsh-cli && npm install --save-exact --no-fund --no-audit @deepseek-ai/dsh@<candidate> && echo <candidate> > ~/.dsh/tools/pinned-version )
   ```
   Never run npm install against `~/.dsh-cli` while `dsh web` is up: the Host serves its browser bundles from that directory and the open page breaks mid-write.

5. **Verify the composed configuration still has the locks.**
   ```bash
   dsh --profile web --dump-config | grep -nE 'id: (session-telemetry-otel|session-log-deepseek|plugin-package-inventory-deepseek|llm-deepseek|agent-default-model)' -A6
   ```
   Confirm `session-telemetry-otel` shows `disabled: true`, the two `-deepseek` upload rows show `enabled: false`, `llm-deepseek` shows `disabled: true`, and `agent-default-model` shows `provider: neuralwatt`. If any is missing, the release changed row semantics; revert with `npm install --save-exact @deepseek-ai/dsh@<previous>` and report.

6. **Refresh the baseline only after a human review.** If the user accepted every finding and the new release is now the trusted reference, record it:
   ```bash
   ./dsh-privacy-check.sh <candidate> --write-baseline ./privacy-baseline.json
   cp ./privacy-baseline.json ~/.dsh/tools/
   ```
   Also update the audited-version note in this file and in `install-dsh-clean.sh`. Never rewrite the baseline on a CLEAN run; a CLEAN run means the old baseline still describes the release.

## Limits to state in the report

- The checker reads bundle configuration, hostnames and dependency names from the npm tarballs. It does not read plugin source. A plugin that already exists in the baseline could change its own behaviour internally without changing its config row; a release-notes read or a source diff of the watched packages is the only way to catch that.
- `--dump-config` shows the composed configuration, not runtime traffic. For a release that adds anything network-related, recommend one packet capture of a short session.
