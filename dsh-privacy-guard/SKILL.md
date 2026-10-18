---
name: dsh-update
description: Upgrade the pinned DeepSeek Harness (dsh) install only after verifying that the release's privacy defaults have not changed relative to the audited baseline.
---

# dsh-update

Upgrade `@deepseek-ai/dsh` to a newer pinned version, but only after the privacy check confirms the release's default-on data paths match the audited baseline. Never pin a version the check has not passed, and never bypass a FAIL without the user explicitly accepting each finding.

## Background

This installation was set up to send nothing anywhere except the model request itself. Three dsh features are on by default upstream and are disabled here by `~/.dsh/cordis.patch.yml`: the session-log upload piggybacked on DeepSeek API requests (`session-log-deepseek`), the installed-plugin inventory on those requests (`plugin-package-inventory-deepseek`), and the feedback-triggered session upload to an OpenTelemetry collector (`session-telemetry-otel`). The DeepSeek API routes themselves are disabled too; the only provider is Neuralwatt. A new release could rename those rows, add new upload paths, or add new hostnames, which is what the check looks for.

## Procedure

1. **Get the current state.** Call the `dsh_privacy_status` tool. It reports the pinned, installed and running versions, the baseline version, the registry polling state, and every newer version the poll has found together with its stored privacy-check verdict. If the user named a version, use it. Otherwise propose the newest `latest` and mention `next` separately; `latest` can lag `next` by a minor release. A candidate already marked `privacy check: CLEAN` needs no new check; one marked `REVIEW NEEDED` needs step 3 on its stored report (`/dsh-privacy check <version>` prints it again). A candidate marked `NOT installable: needs a newer dsh-privacy-guard` lies outside the dsh range this plugin declares in its `engines.dsh`; dsh would disable the plugin on that version. Tell the user to update dsh-privacy-guard first (stop dsh, pull the dsh-privacy repository, re-run its installer with `DSH_ALLOW_EXISTING_HOME=1`) and stop; do not pin by hand around the gate.

2. **Run the check** when the candidate has no stored verdict. Call `dsh_privacy_check` with the version. The result starts with one of:
   - `CLEAN` — bundle configuration, hostnames, environment switches and dependency names are unchanged, and every local override still targets an existing row. Go to step 4.
   - `REVIEW NEEDED` — read every `[FAIL]`, `[WARN]` and `[INFO]` line. Go to step 3.
   - `CHECK FAILED` — the tool itself failed (network, unknown version). Report the stderr and stop.

3. **Interpret findings, in plain words, one sentence each.**
   - `row-changed` on a watched row (the check prints the before/after text): say what the change would send and where. Stop and ask the user before continuing.
   - `row-new` marked FAIL: a new row whose name or config looks like telemetry, upload, analytics or carries a hostname. Say so and ask.
   - `host-new`: a hostname that was not in the baseline. Always stop and ask.
   - `override-orphaned`: one of the user's overrides targets a row id that no longer exists, so the override would silently stop applying. Find the renamed row in the new release's `cordis.patch.yml` (the check downloads it; `npm pack @deepseek-ai/dsh-base@<version>` fetches it again) and propose the exact edit to `~/.dsh/cordis.patch.yml`. Do not pin until the override is fixed.
   - `row-new` / `dep-new` at WARN or INFO: list them. If a name is not obviously inert, fetch its README with `npm pack @deepseek-ai/<pkg>@<version>` and state whether it opens a network path.
   Do not pin unless the user says so for each FAIL finding.

4. **Pin.** `/dsh-privacy update` refuses a version outside the plugin's dsh range (see step 1) as well as one whose check is not CLEAN. Prefer the plugin's own staged path, which never touches the running install: `/dsh-privacy update <version>` (or the web UI's Install button) downloads into `~/.dsh-cli.next`, and the Restart button or the next `dsh web` start swaps it in. Only when that path is unavailable, and only while `dsh web` is NOT running, pin by hand through the shell tool, which requires approval:
   ```bash
   cd ~/.dsh-cli && npm install --save-exact --no-fund --no-audit @deepseek-ai/dsh@<version> && echo <version> > ~/.dsh/tools/pinned-version
   ```
   Never run that command against a live `~/.dsh-cli`: the Host serves its web bundles from there and the open page breaks.

5. **Verify the locks survived.**
   ```bash
   ~/.local/bin/dsh --profile web --dump-config | grep -nE 'id: (session-telemetry-otel|session-log-deepseek|plugin-package-inventory-deepseek|llm-deepseek|agent-default-model)' -A6
   ```
   Confirm `session-telemetry-otel` shows `disabled: true`, the two `-deepseek` upload rows show `enabled: false`, `llm-deepseek` shows `disabled: true`, and `agent-default-model` shows `provider: neuralwatt`. If any is missing, revert with `npm install --save-exact @deepseek-ai/dsh@<previous>` and report. The running Host keeps the old version until the user restarts `dsh web`; say so.

6. **Refresh the baseline only after a human review.** If the user accepted every finding and the new release is now the trusted reference:
   ```bash
   ~/.dsh/tools/dsh-privacy-check.sh <version> --write-baseline ~/.dsh/tools/privacy-baseline.json
   ```
   Never rewrite the baseline on a CLEAN run; CLEAN means the old baseline still describes the release.

## Limits to state in the report

- The check reads bundle configuration, hostnames and dependency names from the npm tarballs. It does not read plugin source, so a plugin already in the baseline could change behaviour internally without changing its config row. Release notes or a source diff of the watched packages is the only way to catch that.
- `--dump-config` shows composed configuration, not runtime traffic. For a release that adds anything network-related, recommend one packet capture of a short session.
