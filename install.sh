#!/usr/bin/env bash
# Bootstrap for the one-line install of dsh-privacy:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/khunsatori/dsh-privacy/main/install.sh)"
#
# It downloads one pinned snapshot of the repository (default: the main branch; set
# DSH_PRIVACY_REF to a tag or commit SHA to pin) into a temporary directory and runs
# install-dsh-clean.sh from there, so the installer finds its checker, baseline and plugin next to
# itself exactly as in a checkout. Every environment variable install-dsh-clean.sh understands
# (NEURALWATT_API_KEY, DSH_VERSION, DSH_HOME, DSH_MODEL, ...) passes through unchanged.
#
# The `bash -c "$(curl ...)"` form keeps your terminal as stdin, so the API-key and nvm prompts work.
# `curl ... | bash` works too; prompts then read from /dev/tty.
set -euo pipefail

REPO="${DSH_PRIVACY_REPO:-khunsatori/dsh-privacy}"
REF="${DSH_PRIVACY_REF:-main}"

command -v curl >/dev/null || { echo "dsh-privacy: curl is required" >&2; exit 1; }
command -v tar  >/dev/null || { echo "dsh-privacy: tar is required" >&2; exit 1; }

TMP="$(mktemp -d -t dsh-privacy)"
trap 'rm -rf "$TMP"' EXIT

fetch() { curl -fsSL --proto '=https' --tlsv1.2 "$1" | tar -xz -C "$TMP" --strip-components=1; }

echo "dsh-privacy: fetching $REPO@$REF" >&2
# A ref can be a branch, a tag, or a commit SHA; codeload serves all three under different paths.
if   fetch "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" 2>/dev/null; then :
elif fetch "https://codeload.github.com/$REPO/tar.gz/refs/tags/$REF"  2>/dev/null; then :
elif fetch "https://codeload.github.com/$REPO/tar.gz/$REF"            2>/dev/null; then :
else echo "dsh-privacy: could not download $REPO at ref '$REF'" >&2; exit 1
fi

[[ -f "$TMP/install-dsh-clean.sh" ]] || { echo "dsh-privacy: snapshot has no install-dsh-clean.sh" >&2; exit 1; }
chmod +x "$TMP/install-dsh-clean.sh" "$TMP/dsh-privacy-check.sh" 2>/dev/null || true
echo "dsh-privacy: running installer from $TMP" >&2
bash "$TMP/install-dsh-clean.sh" "$@"
