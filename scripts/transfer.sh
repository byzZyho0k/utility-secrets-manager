#!/usr/bin/env bash
# scripts/transfer.sh — copy the oh/ credential tree from one Bao to another.
#
# Requires bash 4+ (uses mapfile).  macOS ships bash 3.2; install bash via
# Homebrew and invoke as: /opt/homebrew/bin/bash scripts/transfer.sh
#
# For moving a fleet's credentials to a second, independent OpenBao instance
# (new hardware, a split estate, a rebuilt vault).  Requires an admin token on
# BOTH instances: this is a vault-admin operation, not something oh-cred itself
# can do — oh-cred has no path that reads a secret into the open, deliberately.
#
# Secret values pass through this process's memory and a pipe only.  Nothing is
# printed, nothing is written to disk, nothing is passed as an argument.  Run it
# on a host you already trust with both admin tokens.
#
# If the source vault is on loopback-only (recommended), open an SSH tunnel
# first and point SRC_ADDR at the local end:
#   ssh -f -N -L 18200:127.0.0.1:8200 user@source-host
#   ssh user@source-host 'cat /opt/openbao/tls/tls.crt' > /tmp/src-ca.crt
#   export SRC_ADDR=https://localhost:18200 SRC_CACERT=/tmp/src-ca.crt
#
# Usage:
#   export SRC_ADDR=https://old:8200 SRC_TOKEN=... SRC_CACERT=/opt/openbao/tls/tls.crt
#   export DST_ADDR=https://new:8200 DST_TOKEN=... DST_CACERT=/opt/openbao/tls/tls.crt
#   bash scripts/transfer.sh                  # every hub
#   bash scripts/transfer.sh unh-iol edge1    # only these hubs
#
#   DRY_RUN=1        list what would move, touch nothing
#   SKIP_EXISTING=1  leave destination paths that already hold a secret
#
# Copies, per hub: oh/hubs/<hub>/meta, oh/hubs/<hub>/infra, and every
# oh/hubs/<hub>/users/<org>/<user>.  KV v2 custom_metadata is copied explicitly
# because `kv put` does not carry it, and without it `verify` loses the `role`
# and `exchange_url` that make a credential self-verifying.
#
# Afterwards, against the destination:
#   oh-cred list
#   oh-cred verify-all
# Do not decommission the source until verify-all passes.  A credential checked
# against the wrong hub returns 401 exactly like an expired one.
set -uo pipefail

die() { echo "transfer: $*" >&2; exit 1; }

command -v bao >/dev/null || die "bao not installed"
command -v jq  >/dev/null || die "jq not installed"

DRY_RUN="${DRY_RUN:-0}"
SKIP_EXISTING="${SKIP_EXISTING:-0}"

for v in SRC_ADDR SRC_TOKEN DST_ADDR DST_TOKEN; do
  [ -n "${!v:-}" ] || die "$v is not set (need SRC_ADDR SRC_TOKEN DST_ADDR DST_TOKEN)"
done
[ "$SRC_ADDR" != "$DST_ADDR" ] || die "SRC_ADDR and DST_ADDR are the same vault"

src() { BAO_ADDR="$SRC_ADDR" BAO_TOKEN="$SRC_TOKEN" BAO_CACERT="${SRC_CACERT:-}" bao "$@"; }
dst() { BAO_ADDR="$DST_ADDR" BAO_TOKEN="$DST_TOKEN" BAO_CACERT="${DST_CACERT:-}" bao "$@"; }

src token lookup >/dev/null 2>&1 || die "SRC_TOKEN is not valid at $SRC_ADDR"
dst token lookup >/dev/null 2>&1 || die "DST_TOKEN is not valid at $DST_ADDR"

copied=0 skipped=0 failed=0

_children() {  # _children <path> — immediate children, trailing slash stripped
  src kv list -format=json "$1" 2>/dev/null | jq -r '.[]?' | tr -d /
}

copy_secret() {  # copy_secret <path>
  local p="$1" json data margs=()

  if [ "$SKIP_EXISTING" = 1 ] \
     && dst kv get -format=json "$p" 2>/dev/null | jq -e '.data.data | objects' >/dev/null 2>&1; then
    echo "  exists  $p"; skipped=$((skipped + 1)); return 0
  fi

  # One read: fewer audit entries, and no window for the version to change
  # between checking the secret and writing it.
  json=$(src kv get -format=json "$p" 2>/dev/null)

  # A soft-deleted secret still appears in `kv list` — its metadata outlives its
  # data.  Skip those by name rather than writing a null secret that would look
  # like a real credential on the far side.
  data=$(printf '%s' "$json" | jq -ce '.data.data | objects' 2>/dev/null)
  if [ -z "$data" ]; then
    echo "  skipped $p (no current version — deleted or destroyed)"
    skipped=$((skipped + 1)); return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "  would copy $p"; copied=$((copied + 1)); return 0
  fi

  # Source read to destination write over a pipe: the value is never rendered.
  if ! printf '%s' "$data" | dst kv put "$p" - >/dev/null 2>&1; then
    echo "  FAILED  $p (data)" >&2; failed=$((failed + 1)); return 1
  fi

  # custom_metadata lives on a separate KV v2 API path and is not carried by
  # `kv put`.  Without it a credential arrives with role=- and no exchange_url.
  mapfile -t margs < <(src kv metadata get -format=json "$p" 2>/dev/null \
    | jq -r '(.data.custom_metadata // {}) | to_entries[] | "-custom-metadata=\(.key)=\(.value)"')
  if [ ${#margs[@]} -gt 0 ] && ! dst kv metadata put "${margs[@]}" "$p" >/dev/null 2>&1; then
    echo "  FAILED  $p (metadata)" >&2; failed=$((failed + 1)); return 1
  fi

  echo "  copied  $p"; copied=$((copied + 1))
}

hubs=("$@")
if [ ${#hubs[@]} -eq 0 ]; then
  mapfile -t hubs < <(_children oh/hubs)
  [ ${#hubs[@]} -gt 0 ] || die "no hubs found under oh/hubs at $SRC_ADDR"
fi

[ "$DRY_RUN" = 1 ] && echo "(dry run — nothing will be written)"

for h in "${hubs[@]}"; do
  echo "hub $h"
  for leaf in meta infra; do
    src kv get -format=json "oh/hubs/$h/$leaf" >/dev/null 2>&1 \
      && copy_secret "oh/hubs/$h/$leaf"
  done
  for o in $(_children "oh/hubs/$h/users"); do
    for u in $(_children "oh/hubs/$h/users/$o"); do
      copy_secret "oh/hubs/$h/users/$o/$u"
    done
  done
done

echo ""
printf 'copied %d, skipped %d, failed %d\n' "$copied" "$skipped" "$failed"
if [ "$failed" -gt 0 ]; then exit 1; fi
[ "$DRY_RUN" = 1 ] && exit 0
echo ""
echo "Now, against the destination:"
echo "  oh-cred list"
echo "  oh-cred verify-all"
