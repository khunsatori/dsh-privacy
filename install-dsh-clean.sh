#!/usr/bin/env bash
# One-shot clean install of DeepSeek Harness (dsh) on macOS with:
#   - every default-on outbound data path disabled (see PRIVACY NOTES below)
#   - Neuralwatt (OpenAI-compatible) as the only configured model provider
#   - a pinned dsh version, installed into a private npm prefix (no global install)
#   - a `dsh` wrapper that hard-sets the telemetry opt-out environment
#
# Usage:
#   NEURALWATT_API_KEY=sk-... ./install-dsh-clean.sh
#   (or run without the variable and you will be prompted; input is not echoed)
#
# Tunables (environment variables, all optional):
#   DSH_VERSION       dsh release to pin                  (default: 0.2.1-rc.2, the audited release)
#   DSH_HOME          harness home                        (default: ~/.dsh)
#   DSH_INSTALL_DIR   private npm prefix for the CLI      (default: ~/.dsh-cli)
#   DSH_BIN_DIR       where the `dsh` wrapper goes        (default: ~/.local/bin)
#   DSH_MODEL         default Neuralwatt model id         (default: deepseek-v4.1-flash)
#   DSH_ALLOW_EXISTING_HOME=1   proceed even if DSH_HOME already has content
#   DSH_SKIP_PRIVACY_CHECK=1    skip the release privacy check (not recommended)
#   DSH_AUTO_INSTALL_NODE=1     install nvm + Node without the y/N prompt when Node >= 22 is missing
#   DSH_NODE_VERSION            Node line to install via nvm when needed    (default: 24)
#   NVM_VERSION                 nvm release tag to download when needed     (default: v0.40.8)
#
# Requirements: macOS, curl. Node >= 22 and npm are installed via nvm if absent (prompted).
#
# PRIVACY NOTES (what this script turns off and why):
#   session-log-deepseek            default ON: attaches the full session event log (messages,
#                                   tool results, cwd) to every DeepSeek API request.
#   plugin-package-inventory-deepseek default ON: attaches installed plugin list to DeepSeek requests.
#   session-telemetry-otel          default FEEDBACK_ONLY: any thumbs-up/down or /feedback uploads
#                                   the whole session to dsh-otel-collector.deepseeksvc.com.
#   llm-deepseek, llm-deepseek-account, web-search-deepseek, web-deepseek-api
#                                   DeepSeek API routes; disabled so nothing can reach
#                                   api.deepseek.com even by accident. Remove that block from the
#                                   home patch if you later want DeepSeek as a provider.
#   Desktop-only analytics rows are not mounted by the web profile, so they need no override here.
#   DSH_TELEMETRY_MODE/DSH_TELEMETRY_DISABLED are set by the wrapper as a second lock. They cannot
#   go in $DSH_HOME/.env because dsh rejects DSH_* names there.

set -euo pipefail

DSH_VERSION="${DSH_VERSION:-0.2.1-rc.2}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_INSTALL_DIR="${DSH_INSTALL_DIR:-$HOME/.dsh-cli}"
DSH_BIN_DIR="${DSH_BIN_DIR:-$HOME/.local/bin}"
DSH_MODEL="${DSH_MODEL:-deepseek-v4.1-flash}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }
# Read one line from the terminal even when stdin is a pipe (curl ... | bash).
ask()  { # ask <var> [-s]
  local __var="$1" __flag="${2:-}" __in
  if [[ -t 0 ]]; then __in=/dev/stdin; elif [[ -r /dev/tty ]]; then __in=/dev/tty; else return 1; fi
  if [[ "$__flag" == "-s" ]]; then read -rs "$__var" < "$__in"; printf '\n'; else read -r "$__var" < "$__in"; fi
}

# ---------------------------------------------------------------- preflight
log "Preflight"
[[ "$(uname -s)" == "Darwin" ]] || die "This script targets macOS."
command -v curl >/dev/null || die "curl is required."

# dsh needs Node >= 22 (process.loadEnvFile, Promise.withResolvers). If a suitable node is not on
# PATH, offer to install nvm (pinned release) and Node 24 with it. The wrapper written later pins
# the absolute node binary, so dsh keeps working even in shells where nvm is not sourced.
NODE_MIN_MAJOR=22
NODE_INSTALL_VERSION="${DSH_NODE_VERSION:-24}"
NVM_VERSION="${NVM_VERSION:-v0.40.8}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

node_ok() { command -v node >/dev/null 2>&1 && (( $(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0) >= NODE_MIN_MAJOR )); }
load_nvm() { [[ -s "$NVM_DIR/nvm.sh" ]] && { set +u; . "$NVM_DIR/nvm.sh" --no-use; set -u; return 0; }; return 1; }

if ! node_ok; then
  if command -v node >/dev/null 2>&1; then
    warn "node $(node -v) found but dsh needs >= $NODE_MIN_MAJOR."
  else
    warn "node is not installed."
  fi
  if load_nvm; then
    ok "nvm $(nvm --version) found at $NVM_DIR"
  else
    if [[ "${DSH_AUTO_INSTALL_NODE:-}" != "1" ]]; then
      printf 'Install nvm %s to %s and Node %s with it? This downloads and runs the official nvm installer from\n  https://raw.githubusercontent.com/nvm-sh/nvm/%s/install.sh\nand appends nvm initialisation to your shell rc file. [y/N] ' "$NVM_VERSION" "$NVM_DIR" "$NODE_INSTALL_VERSION" "$NVM_VERSION"
      ask answer || die "No terminal to ask. Re-run with DSH_AUTO_INSTALL_NODE=1 to install nvm + Node $NODE_INSTALL_VERSION unattended."
      [[ "$answer" =~ ^[Yy]$ ]] || die "Node >= $NODE_MIN_MAJOR is required. Install it (https://nodejs.org, 'brew install node', or nvm) and re-run."
    fi
    log "Installing nvm $NVM_VERSION"
    NVM_INSTALLER="$(mktemp -t nvm-install).sh"
    curl -fsSL --proto '=https' --tlsv1.2 "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" -o "$NVM_INSTALLER" \
      || die "could not download the nvm installer"
    mkdir -p "$NVM_DIR"   # the nvm installer refuses a preset NVM_DIR that does not exist yet
    NVM_DIR="$NVM_DIR" bash "$NVM_INSTALLER" || die "nvm installer failed"
    rm -f "$NVM_INSTALLER"
    load_nvm || die "nvm installed but $NVM_DIR/nvm.sh is missing"
    ok "nvm $(nvm --version) installed"
  fi
  log "Installing Node $NODE_INSTALL_VERSION via nvm"
  set +u; nvm install "$NODE_INSTALL_VERSION" >/dev/null || die "nvm install $NODE_INSTALL_VERSION failed"; nvm use "$NODE_INSTALL_VERSION" >/dev/null; set -u
  hash -r
  node_ok || die "Node $NODE_INSTALL_VERSION installed via nvm but still not usable in this shell (found: $(node -v 2>/dev/null || echo none))."
fi
command -v npm >/dev/null || die "npm is required (it ships with Node; your Node install looks incomplete)."
NODE_BIN="$(command -v node)"
NODE_BIN="$(cd "$(dirname "$NODE_BIN")" && pwd -P)/$(basename "$NODE_BIN")"
ok "node $(node -v) at $NODE_BIN, npm $(npm -v)"

if [[ -d "$DSH_HOME" ]] && [[ -n "$(ls -A "$DSH_HOME" 2>/dev/null)" ]] && [[ "${DSH_ALLOW_EXISTING_HOME:-}" != "1" ]]; then
  die "$DSH_HOME already exists and is not empty. This is meant to be a clean install. Move it aside, or set DSH_ALLOW_EXISTING_HOME=1 to layer on top (existing patch files are left untouched)."
fi

if [[ -z "${NEURALWATT_API_KEY:-}" ]]; then
  printf 'Neuralwatt API key (input hidden; get one at https://portal.neuralwatt.com): '
  ask NEURALWATT_API_KEY -s || die "No terminal to ask for the key. Re-run with NEURALWATT_API_KEY=sk-... in the environment."
fi
[[ -n "$NEURALWATT_API_KEY" ]] || die "No API key given."

# ---------------------------------------------------------------- privacy check of the pinned release
if [[ "${DSH_SKIP_PRIVACY_CHECK:-}" != "1" ]]; then
  if [[ -x "$SCRIPT_DIR/dsh-privacy-check.sh" ]]; then
    log "Privacy check of @deepseek-ai/dsh@$DSH_VERSION against the audited baseline"
    if ! "$SCRIPT_DIR/dsh-privacy-check.sh" "$DSH_VERSION" --baseline "$SCRIPT_DIR/privacy-baseline.json" --home "$DSH_HOME"; then
      die "Privacy check reported changes. Review them above; re-run with DSH_SKIP_PRIVACY_CHECK=1 only if you accept them."
    fi
  else
    warn "dsh-privacy-check.sh not found next to this script; skipping release check."
  fi
fi

# ---------------------------------------------------------------- harness home + locked privacy patch
log "Writing harness home at $DSH_HOME"
mkdir -p "$DSH_HOME/profiles/web" "$DSH_HOME/tools"
chmod 700 "$DSH_HOME"

HOME_PATCH="$DSH_HOME/cordis.patch.yml"
if [[ -e "$HOME_PATCH" ]]; then
  warn "$HOME_PATCH exists; leaving it alone. Make sure it contains the privacy rows."
else
  cat > "$HOME_PATCH" <<'YAML'
# Home-level patch: applied AFTER every profile's own patch, so these rows cannot be
# undone from the Web UI. Keep the privacy block intact. Written by install-dsh-clean.sh.

# --- privacy: no data leaves this machine except the model request itself ---
- id: session-telemetry-otel
  disabled: true
- id: session-log-deepseek
  config:
    enabled: false
- id: plugin-package-inventory-deepseek
  config:
    enabled: false

# --- no DeepSeek API routes at all (remove this block to allow DeepSeek as a provider) ---
- id: llm-deepseek
  disabled: true
- id: llm-deepseek-account
  disabled: true
- id: web-search-deepseek
  disabled: true
- id: web-deepseek-api
  disabled: true
YAML
  ok "privacy patch -> $HOME_PATCH"
fi

# ---------------------------------------------------------------- web + headless profiles: Neuralwatt provider
# Provider config lives in each profile's own patch (not the home patch) so the Settings UI and the
# model picker can still edit it. Written for both shipped profiles so `dsh --profile headless` works too.
for PROFILE in web headless; do
PROFILE_PATCH="$DSH_HOME/profiles/$PROFILE/cordis.patch.yml"
mkdir -p "$(dirname "$PROFILE_PATCH")"
if [[ -e "$PROFILE_PATCH" ]]; then
  warn "$PROFILE_PATCH exists; leaving it alone. Add the Neuralwatt provider there yourself if missing."
else
  cat > "$PROFILE_PATCH" <<YAML
# ${PROFILE} profile patch. The Settings UI edits this file; the home patch above still wins on conflict.
# Model data transcribed from https://portal.neuralwatt.com/models on 2026-10-18.
#   contextWindow / maxTokens are pi-ai capability descriptors; dsh does NOT send maxTokens as the
#   request cap unless you also set a per-model request cap, so "shared with input" models declare
#   their full context as maxTokens.
#   reasoningEfforts keys are the levels the picker offers; values are the reasoning_effort sent.
#   Only levels Neuralwatt lists for that model are declared. Models whose reasoning is
#   "always on" (glm-5.3, glm-5.3-flash) have no off level; Neuralwatt exposes their non-thinking
#   siblings and kimi/qwen non-thinking variants as separate ids (…-fast), declared without
#   reasoning levels.
- id: llm-pi-ai
  config:
    providers:
      neuralwatt:
        displayName: Neuralwatt
        apiKeyEnv: NEURALWATT_API_KEY
        api: openai-completions
        baseURL: https://api.neuralwatt.com/v1
        compat:
          supportsDeveloperRole: false
          maxTokensField: max_tokens
        reasoning: high
        models:
          # DeepSeek V4.1 Flash: 1M ctx, 393K out, vision. Levels: max, xhigh, high(default), low, none.
          - id: deepseek-v4.1-flash
            contextWindow: 1048560
            maxTokens: 393216
            input: [text, image]
            reasoningEfforts: { off: none, low: low, medium: medium, high: high, xhigh: xhigh, max: max }
          # DeepSeek V4 Flash: 1M ctx, 393K out, text only. Server default is none (no thinking).
          - id: deepseek-v4-flash
            contextWindow: 1048560
            maxTokens: 393216
            reasoningEfforts: { off: none, low: low, high: high, max: max }
          # GLM-5.3: 1M ctx shared in/out, text only, reasoning always on (no off level).
          - id: glm-5.3
            contextWindow: 1048560
            maxTokens: 1048560
            reasoningEfforts: { low: low, high: high, max: max }
          # GLM-5.3 Flash: as above, with vision.
          - id: glm-5.3-flash
            contextWindow: 1048560
            maxTokens: 1048560
            input: [text, image]
            reasoningEfforts: { low: low, high: high, max: max }
          # Kimi K3: 1M ctx shared, vision. kimi-k3-fast is the non-thinking serving of the same weights.
          - id: kimi-k3
            contextWindow: 1048560
            maxTokens: 1048560
            input: [text, image]
            reasoningEfforts: { off: none, low: low, high: high, max: max }
          - id: kimi-k3-fast
            contextWindow: 1048560
            maxTokens: 1048560
            input: [text, image]
          # Qwen3.6 35B: 262K ctx shared, vision. Every effort maps to high; qwen3.6-35b-fast is non-thinking.
          - id: qwen3.6-35b
            contextWindow: 262128
            maxTokens: 262128
            input: [text, image]
            reasoningEfforts: { off: none, high: high, max: max }
          - id: qwen3.6-35b-fast
            contextWindow: 262128
            maxTokens: 262128
            input: [text, image]
          # Qwen3.8 27B: 262K ctx, 131K out, vision. Levels: xhigh(default), medium, low, none.
          - id: qwen-3.8-27b
            contextWindow: 262128
            maxTokens: 131072
            input: [text, image]
            reasoningEfforts: { off: none, low: low, medium: medium, high: high, xhigh: xhigh, max: max }
          # MiMo V2.6 Pro: 1M ctx, 393K out, vision + audio input. Levels collapse to high(default) or none.
          - id: mimo-v2.6-pro
            contextWindow: 1048560
            maxTokens: 393216
            input: [text, image]
            reasoningEfforts: { off: none, high: high, max: max }
          # Gemma 4 31B: 262K ctx, 16K out, vision. Any effort maps to max; none is the server default.
          - id: gemma-4-31b
            contextWindow: 262128
            maxTokens: 16384
            input: [text, image]
            reasoningEfforts: { off: none, high: high, max: max }
- id: agent-default-model
  config:
    provider: neuralwatt
    model: ${DSH_MODEL}
YAML
  ok "Neuralwatt provider -> $PROFILE_PATCH (default model: $DSH_MODEL)"
fi
done

# ---------------------------------------------------------------- API key in the harness-home .env
ENV_FILE="$DSH_HOME/.env"
if grep -qs '^NEURALWATT_API_KEY=' "$ENV_FILE" 2>/dev/null; then
  warn "$ENV_FILE already has NEURALWATT_API_KEY; not overwriting."
else
  umask 077
  printf 'NEURALWATT_API_KEY=%s\n' "$NEURALWATT_API_KEY" >> "$ENV_FILE"
  umask 022
  ok "API key -> $ENV_FILE (mode 600)"
fi
unset NEURALWATT_API_KEY

# ---------------------------------------------------------------- install pinned CLI into a private prefix
log "Installing @deepseek-ai/dsh@$DSH_VERSION into $DSH_INSTALL_DIR"
if pgrep -f "$DSH_INSTALL_DIR/node_modules/.bin/dsh" >/dev/null 2>&1; then
  die "dsh is running from $DSH_INSTALL_DIR. Stop it first: the Host serves its web bundles from that directory and replacing them underneath an open page breaks it."
fi
mkdir -p "$DSH_INSTALL_DIR"
[[ -f "$DSH_INSTALL_DIR/package.json" ]] || printf '{ "name": "dsh-pinned", "private": true }\n' > "$DSH_INSTALL_DIR/package.json"
( cd "$DSH_INSTALL_DIR" && npm install --save-exact --no-fund --no-audit --loglevel=error "@deepseek-ai/dsh@$DSH_VERSION" )
DSH_REAL_BIN="$DSH_INSTALL_DIR/node_modules/.bin/dsh"
[[ -x "$DSH_REAL_BIN" ]] || die "install finished but $DSH_REAL_BIN is missing"
ok "installed $("$DSH_REAL_BIN" --version 2>/dev/null || echo "$DSH_VERSION")"

# ---------------------------------------------------------------- wrapper with hard telemetry opt-out
log "Writing wrapper $DSH_BIN_DIR/dsh"
mkdir -p "$DSH_BIN_DIR"
cat > "$DSH_BIN_DIR/dsh" <<WRAP
#!/usr/bin/env bash
# dsh wrapper written by install-dsh-clean.sh. Second lock on top of the config patch.
# - Pins the Node binary used at install time (nvm installs are not on PATH in non-interactive shells).
# - Relaunches dsh when the privacy-guard plugin's Restart button left a marker file, so a one-click
#   update finishes on the newly pinned version without touching the terminal.
export DSH_HOME="\${DSH_HOME:-$DSH_HOME}"
export DSH_TELEMETRY_MODE=DISABLED
export DSH_TELEMETRY_DISABLED=1
NODE_BIN="$NODE_BIN"
INSTALL_DIR="$DSH_INSTALL_DIR"
DSH_REAL_BIN="\$INSTALL_DIR/node_modules/.bin/dsh"
MARKER="\$DSH_HOME/tools/restart-requested"
PENDING="\$DSH_HOME/tools/pending-install.json"
if [[ -x "\$NODE_BIN" ]]; then export PATH="\$(dirname "\$NODE_BIN"):\$PATH"; else NODE_BIN=""; fi

# A staged install (<INSTALL_DIR>.next, written by the privacy-guard Update button) is swapped in
# only while dsh is NOT running: here, before launch, and again after a requested restart.
swap_in_pending() {
  [[ -f "\$PENDING" ]] || return 0
  local stage version
  stage="\$INSTALL_DIR.next"
  version="\$(sed -nE 's/.*"version": *"([^"]+)".*/\\1/p' "\$PENDING" | head -1)"
  if [[ -x "\$stage/node_modules/.bin/dsh" ]]; then
    rm -rf "\$INSTALL_DIR.prev"
    mv "\$INSTALL_DIR" "\$INSTALL_DIR.prev" && mv "\$stage" "\$INSTALL_DIR" \\
      && { printf '%s\\n' "\$version" > "\$DSH_HOME/tools/pinned-version"; echo "dsh: switched to \$version (previous install kept at \$INSTALL_DIR.prev)" >&2; } \\
      || { echo "dsh: swap of staged install failed; keeping the current version" >&2; [[ -d "\$INSTALL_DIR" ]] || mv "\$INSTALL_DIR.prev" "\$INSTALL_DIR"; }
  else
    echo "dsh: pending install at \$stage is incomplete; ignoring it" >&2
  fi
  rm -f "\$PENDING"
}

rm -f "\$MARKER"
swap_in_pending
while :; do
  if [[ -n "\$NODE_BIN" ]]; then "\$NODE_BIN" "\$DSH_REAL_BIN" "\$@"; else "\$DSH_REAL_BIN" "\$@"; fi
  code=\$?
  if [[ -f "\$MARKER" ]]; then
    rm -f "\$MARKER"
    swap_in_pending
    echo "dsh: restart requested by privacy-guard; relaunching \$(cat "\$DSH_HOME/tools/pinned-version" 2>/dev/null || echo dsh)" >&2
    sleep 1
    continue
  fi
  exit \$code
done
WRAP
chmod 755 "$DSH_BIN_DIR/dsh"
ok "wrapper ready"
case ":$PATH:" in *":$DSH_BIN_DIR:"*) ;; *) warn "$DSH_BIN_DIR is not on your PATH. Add:  export PATH=\"$DSH_BIN_DIR:\$PATH\"";; esac

# ---------------------------------------------------------------- keep the checker with the install
if [[ -f "$SCRIPT_DIR/dsh-privacy-check.sh" ]]; then
  cp "$SCRIPT_DIR/dsh-privacy-check.sh" "$DSH_HOME/tools/"
  [[ -f "$SCRIPT_DIR/privacy-baseline.json" ]] && cp "$SCRIPT_DIR/privacy-baseline.json" "$DSH_HOME/tools/"
  printf '%s\n' "$DSH_VERSION" > "$DSH_HOME/tools/pinned-version"
  ok "checker + baseline copied to $DSH_HOME/tools/"
fi

# ---------------------------------------------------------------- privacy-guard plugin (/dsh-privacy, dsh_privacy_* tools, dsh-update skill)
if [[ -f "$SCRIPT_DIR/dsh-privacy-guard/package.json" ]]; then
  log "Installing the dsh-privacy-guard plugin"
  PLUGIN_DIR="$DSH_HOME/plugins/dsh-privacy-guard"
  mkdir -p "$DSH_HOME/plugins"
  rm -rf "$PLUGIN_DIR"
  cp -R "$SCRIPT_DIR/dsh-privacy-guard" "$PLUGIN_DIR"
  rm -rf "$PLUGIN_DIR/node_modules"
  # The plugin carries its own copies of the checker and baseline; keep them identical to the installed ones.
  mkdir -p "$PLUGIN_DIR/scripts"
  cp "$SCRIPT_DIR/dsh-privacy-check.sh" "$PLUGIN_DIR/scripts/"
  [[ -f "$SCRIPT_DIR/privacy-baseline.json" ]] && cp "$SCRIPT_DIR/privacy-baseline.json" "$PLUGIN_DIR/"
  # `dsh plugin add` forwards to pnpm. Use the one on PATH, else a private copy under the install prefix.
  if ! command -v pnpm >/dev/null 2>&1; then
    log "pnpm not found; installing a private copy under $DSH_INSTALL_DIR"
    ( cd "$DSH_INSTALL_DIR" && npm install --no-fund --no-audit --loglevel=error pnpm@latest-10 )
    export PATH="$DSH_INSTALL_DIR/node_modules/.bin:$PATH"
  fi
  for PROFILE in web headless; do
    if DSH_HOME="$DSH_HOME" DSH_TELEMETRY_MODE=DISABLED "$DSH_REAL_BIN" plugin --profile "$PROFILE" add "$PLUGIN_DIR" >/dev/null 2>"$DSH_HOME/plugins/.add-$PROFILE.log"; then
      ok "dsh-privacy-guard -> profile $PROFILE"
    else
      warn "could not add dsh-privacy-guard to profile $PROFILE; see $DSH_HOME/plugins/.add-$PROFILE.log"
    fi
  done
else
  warn "dsh-privacy-guard/ not found next to this script; skipping the plugin."
fi

# ---------------------------------------------------------------- verify the composed config
log "Verifying composed web profile config"
DUMP="$(DSH_HOME="$DSH_HOME" DSH_TELEMETRY_MODE=DISABLED "$DSH_REAL_BIN" --profile web --dump-config 2>/dev/null || true)"
[[ -n "$DUMP" ]] || die "dsh --dump-config produced no output"
check_row() { # id, expected-regex, description
  local block
  block="$(printf '%s\n' "$DUMP" | awk -v id="$1" '
    $0 ~ "id: *\"?" id "\"?$" {p=1; print; next}
    p && /^[[:space:]]*-[[:space:]]*id:/ {exit}
    p {print}')"
  if printf '%s' "$block" | grep -qE "$2"; then ok "$3"; else warn "could not confirm: $3"; FAIL=1; fi
}
FAIL=0
check_row session-telemetry-otel            'disabled: *true'   'session-telemetry-otel disabled'
check_row session-log-deepseek              'enabled: *false'   'session-log-deepseek upload off'
check_row plugin-package-inventory-deepseek 'enabled: *false'   'plugin inventory upload off'
check_row llm-deepseek                      'disabled: *true'   'DeepSeek API-key route disabled'
check_row agent-default-model               'provider: *neuralwatt' 'default provider is neuralwatt'
if (( FAIL )); then
  warn "Some rows could not be confirmed from --dump-config. Inspect:  dsh --profile web --dump-config | less"
fi

cat <<EOF

Done. Start the Web UI with:

  dsh web

It binds 127.0.0.1:3080 and opens your browser. Pass --no-open to skip the browser.
Pinned version: $DSH_VERSION   Home: $DSH_HOME   Wrapper: $DSH_BIN_DIR/dsh

Before trusting it, do one network capture (Little Snitch / Lulu / 'sudo tcpdump -i en0 port 443')
during a short session: the only destination should be api.neuralwatt.com.

Upgrading later: the web UI polls the npm registry once a day and shows "Update to <version>" in the
sidebar footer only for a release that passes the privacy check; Install stages it next to the current
install and Restart swaps it in. The same works from the composer: /dsh-privacy update <version>.
Manual path, only while dsh is NOT running:
  $DSH_HOME/tools/dsh-privacy-check.sh <new-version> --baseline $DSH_HOME/tools/privacy-baseline.json --home $DSH_HOME
  ( cd $DSH_INSTALL_DIR && npm install --save-exact @deepseek-ai/dsh@<new-version> )
EOF
