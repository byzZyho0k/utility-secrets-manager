#!/usr/bin/env bash
# scripts/import-seal.sh — store a hub's own OpenBao seal material in the vault.
#
# Writes oh/seal/<hub> from a bao init output file (the JSON that
# `bao operator init` / deploy-mgmt-hub.sh emits, containing keys_base64 and
# root_token). Never prints a secret value.
#
# Usage:
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=/opt/openbao/tls/tls.crt
#   bao login -method=userpass username=admin
#   bash scripts/import-seal.sh <hub> <bao_addr> <keys.json>
#
# Example — capturing edge1's, which currently exists only on edge1 itself:
#   scp edge:/home/edge/bao-keys.json /tmp/edge1-keys.json
#   bash scripts/import-seal.sh edge1 http://192.168.50.85:8200 /tmp/edge1-keys.json
#   shred -u /tmp/edge1-keys.json
#
# This needs a human token: oh-cred's AppRoles are read-only by design and
# cannot write. That is deliberate — see docs/RATIONALE.md.
set -uo pipefail

die() { echo "import-seal: $*" >&2; exit 1; }

HUB="${1:-}"; ADDR="${2:-}"; KEYS="${3:-}"
[ -n "$HUB" ] && [ -n "$ADDR" ] && [ -n "$KEYS" ] \
  || die "usage: import-seal.sh <hub> <bao_addr> <keys.json>"
[ -r "$KEYS" ] || die "cannot read $KEYS"

command -v bao >/dev/null || die "bao not installed"
command -v jq  >/dev/null || die "jq not installed"
bao token lookup >/dev/null 2>&1 \
  || die "no valid BAO_TOKEN — log in first: bao login -method=userpass username=admin"

# Accept either {"keys_base64":[...],"root_token":"..."} or a bare key string.
if jq -e 'has("keys_base64")' "$KEYS" >/dev/null 2>&1; then
  n=$(jq '.keys_base64 | length' "$KEYS")
  [ "$n" -ge 1 ] || die "$KEYS has an empty keys_base64 array"
  payload=$(jq -c '{unseal_keys_b64: .keys_base64, root_token: (.root_token // "")}' "$KEYS")
else
  die "$KEYS does not look like bao init output (no keys_base64)"
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
THRESHOLD=$(jq -r '.threshold // 1' "$KEYS" 2>/dev/null)
[ "$THRESHOLD" = "null" ] && THRESHOLD=1

# Pipe the JSON in on stdin so no secret ever appears in argv or `ps` output.
printf '%s' "$payload" | bao kv put "oh/seal/$HUB" - >/dev/null \
  || die "failed writing oh/seal/$HUB"

bao kv metadata put \
  -custom-metadata="hub=$HUB" \
  -custom-metadata="bao_addr=$ADDR" \
  -custom-metadata="seal_type=shamir" \
  -custom-metadata="shares=$n" \
  -custom-metadata="threshold=$THRESHOLD" \
  -custom-metadata="imported_at=$NOW" \
  "oh/seal/$HUB" >/dev/null || die "failed writing metadata for oh/seal/$HUB"

echo "  ok: oh/seal/$HUB  ($n share(s), threshold $THRESHOLD, $ADDR)"
echo "  verify with: oh-cred seal-status $HUB"
echo "  NOTE: shred the source file — it is now redundant plaintext."
