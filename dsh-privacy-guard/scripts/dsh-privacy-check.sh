#!/usr/bin/env bash
# dsh-privacy-check.sh — compare a published @deepseek-ai/dsh release's default bundle
# configuration against an audited baseline BEFORE pinning it.
#
# What it inspects (all from the npm tarballs; no git clone, nothing executed):
#   - packages/bundle/base   -> cordis.patch.yml        (every CLI/web/headless profile)
#   - packages/bundle/web-app-> cordis.patch.yml + presets/*.patch.yml (web + desktop profiles)
#   - the dependency names of dsh, dsh-base and dsh-web-app
#
# What it reports:
#   FAIL  a watched privacy row changed, was removed, or a new row looks like telemetry/upload;
#         a new external hostname appeared in the bundle config; a new dependency name looks like
#         telemetry; or one of YOUR local patch overrides targets a row id that no longer exists
#         (your override would silently stop applying).
#   WARN  other new rows, new process.env references, other new dependencies.
#
# Usage:
#   dsh-privacy-check.sh <version> [--baseline FILE] [--home DIR] [--json]
#   dsh-privacy-check.sh <version> --write-baseline FILE     # record an audited release
# Exit: 0 clean, 1 needs review (FAIL present), 2 tool error.

set -euo pipefail

VERSION="${1:-}"; shift || true
BASELINE=""; WRITE=""; HOME_DIR="${DSH_HOME:-$HOME/.dsh}"; JSON=0
while (( $# )); do
  case "$1" in
    --baseline) BASELINE="$2"; shift 2;;
    --write-baseline) WRITE="$2"; shift 2;;
    --home) HOME_DIR="$2"; shift 2;;
    --json) JSON=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -n "$VERSION" ]] || { echo "usage: $0 <version> [--baseline FILE | --write-baseline FILE] [--home DIR] [--json]" >&2; exit 2; }
if [[ -z "$WRITE" && -z "$BASELINE" ]]; then
  BASELINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/privacy-baseline.json"
fi
command -v npm >/dev/null || { echo "npm required" >&2; exit 2; }
command -v node >/dev/null || { echo "node required" >&2; exit 2; }

WORK="$(mktemp -d -t dsh-privacy-check)"
trap 'rm -rf "$WORK"' EXIT

# ---- resolve the bundle versions the CLI pins, then fetch the tarballs -------------------
echo "fetching @deepseek-ai/dsh@$VERSION metadata ..." >&2
npm view "@deepseek-ai/dsh@$VERSION" dependencies --json > "$WORK/dsh-deps.json" 2>/dev/null \
  || { echo "npm view failed: is $VERSION a published version?" >&2; exit 2; }
BASE_VER="$(node -e 'const d=require(process.argv[1]);process.stdout.write(d["@deepseek-ai/dsh-base"]||"")' "$WORK/dsh-deps.json")"
WEB_VER="$(node -e 'const d=require(process.argv[1]);process.stdout.write(d["@deepseek-ai/dsh-web-app"]||"")' "$WORK/dsh-deps.json")"
BASE_VER="${BASE_VER:-$VERSION}"; WEB_VER="${WEB_VER:-$VERSION}"

fetch() { # pkg ver dest
  mkdir -p "$3"
  npm pack "@deepseek-ai/$1@$2" --pack-destination "$3" --loglevel=error >/dev/null 2>&1 \
    || { echo "npm pack @deepseek-ai/$1@$2 failed" >&2; exit 2; }
  tar -xzf "$3"/*.tgz -C "$3"
}
echo "fetching dsh-base@$BASE_VER and dsh-web-app@$WEB_VER tarballs ..." >&2
fetch dsh-base "$BASE_VER" "$WORK/base"
fetch dsh-web-app "$WEB_VER" "$WORK/web"
npm view "@deepseek-ai/dsh-base@$BASE_VER" dependencies --json > "$WORK/base-deps.json" 2>/dev/null || echo '{}' > "$WORK/base-deps.json"
npm view "@deepseek-ai/dsh-web-app@$WEB_VER" dependencies --json > "$WORK/web-deps.json" 2>/dev/null || echo '{}' > "$WORK/web-deps.json"

# ---- parse + compare in node ------------------------------------------------------------
node - "$WORK" "$VERSION" "$BASELINE" "$WRITE" "$HOME_DIR" "$JSON" <<'NODE'
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const [work, version, baselinePath, writePath, homeDir, jsonOut] = process.argv.slice(2);

// Rows whose text must not change without a human looking at it.
const WATCHED = [
  'otel', 'session-telemetry-otel', 'session-log-deepseek', 'plugin-package-inventory-deepseek',
  'desktop-product-telemetry', 'product-analytics', 'message-feedback', 'command-feedback',
  'ui-message-feedback', 'deepseek-account-platform', 'llm-deepseek', 'llm-deepseek-account',
  'web-search-deepseek', 'web-deepseek-api', 'agent-default-model', 'deepseek-llm-api-extensions',
];
const SENSITIVE = /telemetry|otel|otlp|analytics|feedback|inventory|upload|report|collector|metric|beacon|track|crash|diagnos|sentry|posthog|segment|mixpanel|amplitude/i;
const HOST_RE = /https?:\/\/([a-z0-9.-]+\.[a-z]{2,})/gi;
const ENV_RE = /process\.env\.([A-Z0-9_]+)/g;

function* patchFiles(dir, bundle) {
  const pkg = path.join(dir, 'package');
  const main = path.join(pkg, 'cordis.patch.yml');
  if (fs.existsSync(main)) yield [bundle, main];
  const presets = path.join(pkg, 'presets');
  if (fs.existsSync(presets)) for (const f of fs.readdirSync(presets)) if (f.endsWith('.yml')) yield [`${bundle}/presets/${f}`, path.join(presets, f)];
}

// Split a patch file into `- id:` blocks. A block runs until the next non-blank line whose
// indent is <= the indent of its own "- id:" line. Comment lines are dropped from the block text.
function parseRows(text) {
  const lines = text.split(/\r?\n/), rows = {};
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(\s*)-\s+id:\s*['"]?([^'"\s]+)['"]?\s*$/);
    if (!m) continue;
    const indent = m[1].length, body = [lines[i]];
    let j = i + 1;
    for (; j < lines.length; j++) {
      const l = lines[j];
      if (l.trim() === '') { body.push(l); continue; }
      const ind = l.match(/^(\s*)/)[1].length;
      if (ind <= indent) break;
      body.push(l);
    }
    const clean = body.filter(l => !/^\s*#/.test(l)).map(l => l.replace(/\s+#.*$/, '').trimEnd()).filter(Boolean);
    const txt = clean.join('\n');
    const name = (txt.match(/^\s+name:\s*['"]?([^'"\n]+)/m) || [])[1] || '';
    const disabled = (txt.match(/^\s+disabled:\s*(.+)$/m) || [])[1] || '';
    rows[m[2]] = { name: name.trim(), disabled: disabled.trim(), text: txt, hash: crypto.createHash('sha256').update(txt).digest('hex').slice(0, 16) };
    i = j - 1;
  }
  return rows;
}

const snapshot = { version, rows: {}, hosts: new Set(), envRefs: new Set(), packages: new Set(), files: {} };
for (const [bundle, dir] of [['base', path.join(work, 'base')], ['web-app', path.join(work, 'web')]]) {
  for (const [label, file] of patchFiles(dir, bundle)) {
    const text = fs.readFileSync(file, 'utf8');
    snapshot.files[label] = crypto.createHash('sha256').update(text).digest('hex').slice(0, 16);
    const stripped = text.split('\n').filter(l => !/^\s*#/.test(l)).join('\n');
    for (const m of stripped.matchAll(HOST_RE)) snapshot.hosts.add(m[1].toLowerCase());
    for (const m of stripped.matchAll(ENV_RE)) snapshot.envRefs.add(m[1]);
    for (const [id, row] of Object.entries(parseRows(text))) snapshot.rows[`${label}:${id}`] = row;
  }
}
for (const f of ['dsh-deps.json', 'base-deps.json', 'web-deps.json']) {
  try { for (const k of Object.keys(JSON.parse(fs.readFileSync(path.join(work, f), 'utf8')) || {})) snapshot.packages.add(k); } catch {}
}
const plain = { ...snapshot, hosts: [...snapshot.hosts].sort(), envRefs: [...snapshot.envRefs].sort(), packages: [...snapshot.packages].sort(), generatedAt: new Date().toISOString() };

if (writePath) {
  fs.writeFileSync(writePath, JSON.stringify(plain, null, 2) + '\n');
  console.log(`baseline written: ${writePath} (${Object.keys(plain.rows).length} rows, ${plain.hosts.length} hosts, ${plain.packages.length} packages)`);
  process.exit(0);
}

if (!fs.existsSync(baselinePath)) { console.error(`baseline not found: ${baselinePath}`); process.exit(2); }
const base = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
const findings = []; // {level, kind, msg, detail?}
const add = (level, kind, msg, detail) => findings.push({ level, kind, msg, ...(detail ? { detail } : {}) });

// 1. watched rows: removed or changed
for (const key of Object.keys(base.rows)) {
  const id = key.split(':').pop();
  const before = base.rows[key], after = plain.rows[key];
  if (!after) { add(WATCHED.includes(id) ? 'FAIL' : 'WARN', 'row-removed', `${key} removed (was ${before.name})`); continue; }
  if (before.hash !== after.hash) {
    const watched = WATCHED.includes(id);
    // Full before/after text only for watched rows; other changes get one line (prompt text churn is noise here).
    add(watched ? 'FAIL' : 'INFO', 'row-changed', `${key} changed${watched ? '' : ' (not a watched row; config text differs)'}`,
      watched ? `--- baseline\n${before.text}\n+++ ${version}\n${after.text}` : undefined);
  }
}
// 2. new rows
for (const [key, row] of Object.entries(plain.rows)) {
  if (base.rows[key]) continue;
  const suspicious = SENSITIVE.test(row.name) || SENSITIVE.test(key) || HOST_RE.test(row.text) || ENV_RE.test(row.text);
  add(suspicious ? 'FAIL' : 'WARN', 'row-new', `new row ${key} (${row.name || 'no name'})${row.disabled ? ` disabled: ${row.disabled}` : ''}`, suspicious ? row.text : undefined);
}
// 3. hosts
for (const h of plain.hosts) if (!base.hosts.includes(h)) add('FAIL', 'host-new', `new hostname in bundle config: ${h}`);
// 4. env refs
for (const e of plain.envRefs) if (!base.envRefs.includes(e)) add('WARN', 'env-new', `new environment switch referenced: ${e}`);
// 5. packages
for (const p of plain.packages) if (!base.packages.includes(p)) add(SENSITIVE.test(p) ? 'FAIL' : 'INFO', 'dep-new', `new dependency: ${p}`);
// 6. local overrides still target existing rows. Only ids the BASELINE bundles knew are judged:
//    an override of a row that another bundle supplies (an installed plugin such as privacy-guard)
//    is outside these two bundles and cannot be orphaned by a dsh release.
const liveIds = new Set(Object.keys(plain.rows).map(k => k.split(':').pop()));
const baselineIds = new Set(Object.keys(base.rows).map(k => k.split(':').pop()));
const localPatches = [path.join(homeDir, 'cordis.patch.yml')];
const profiles = path.join(homeDir, 'profiles');
if (fs.existsSync(profiles)) for (const p of fs.readdirSync(profiles)) localPatches.push(path.join(profiles, p, 'cordis.patch.yml'));
for (const f of localPatches) {
  if (!fs.existsSync(f)) continue;
  for (const id of Object.keys(parseRows(fs.readFileSync(f, 'utf8')))) {
    if (baselineIds.has(id) && !liveIds.has(id)) add('FAIL', 'override-orphaned', `${f} overrides row "${id}" which does not exist in ${version}; your override would silently stop applying`);
    else if (!baselineIds.has(id) && !liveIds.has(id)) add('INFO', 'override-external', `${f} overrides row "${id}", which neither the baseline nor ${version} ships (an installed plugin's row?)`);
  }
}

const rank = { FAIL: 0, WARN: 1, INFO: 2 };
findings.sort((a, b) => rank[a.level] - rank[b.level]);
const fails = findings.filter(f => f.level === 'FAIL').length;
if (jsonOut === '1') {
  console.log(JSON.stringify({ version, baseline: base.version, verdict: fails ? 'REVIEW' : 'CLEAN', findings }, null, 2));
} else {
  console.log(`\ndsh privacy check: ${version}  vs baseline ${base.version}`);
  console.log(`rows: ${Object.keys(plain.rows).length} (baseline ${Object.keys(base.rows).length})  hosts: ${plain.hosts.join(', ') || '-'}\n`);
  if (!findings.length) console.log('No differences in bundle configuration, hostnames, environment switches or dependency names.');
  for (const f of findings) {
    console.log(`[${f.level}] ${f.msg}`);
    if (f.detail) console.log(f.detail.split('\n').map(l => '        ' + l).join('\n'));
  }
  console.log(`\nverdict: ${fails ? `REVIEW NEEDED (${fails} FAIL)` : 'CLEAN'}`);
  if (!fails) console.log('Default-on data paths unchanged; your local overrides still match. Safe to pin, then re-verify with: dsh --profile web --dump-config');
}
process.exit(fails ? 1 : 0);
NODE
