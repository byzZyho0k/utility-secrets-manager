#!/usr/bin/env bash
# scripts/import-wifi.sh — store a wifi PSK in the vault.
#
# Writes oh/wifi/<slug>. Keyed by slug because real SSIDs contain spaces
# ("Pit of Despair"), which make poor KV path components; the true SSID is
# stored in the secret so `oh-cred wifi-run` exports exactly what a supplicant
# needs.
#
# The PSK is read from a prompt or from $WIFI_PSK, never from the command line,
# so it cannot land in shell history or `ps` output.
#
# Usage:
#   bao login -method=userpass username=admin
#   bash scripts/import-wifi.sh <slug> <ssid> [hosts]
#
# Example:
#   bash scripts/import-wifi.sh pit-of-despair 'Pit of Despair' 'rpi-*,edge1,edge2'
set -uo pipefail

die() { echo "import-wifi: $*" >&2; exit 1; }

SLUG="${1:-}"; SSID="${2:-}"; HOSTS="${3:-}"
[ -n "$SLUG" ] && [ -n "$SSID" ] || die "usage: import-wifi.sh <slug> <ssid> [hosts]"
case "$SLUG" in *[!a-z0-9-]*) die "slug must be lowercase letters, digits and hyphens";; esac

command -v bao >/dev/null || die "bao not installed"
bao token lookup >/dev/null 2>&1 \
  || die "no valid BAO_TOKEN — log in first: bao login -method=userpass username=admin"

PSK="${WIFI_PSK:-}"
if [ -z "$PSK" ]; then
  read -r -s -p "PSK for '$SSID': " PSK; echo
fi
[ -n "$PSK" ] || die "empty PSK"
[ "${#PSK}" -ge 8 ] || die "a WPA2 PSK must be at least 8 characters"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# stdin, not argv.
printf '{"ssid":%s,"psk":%s}' \
  "$(printf '%s' "$SSID" | jq -Rs .)" \
  "$(printf '%s' "$PSK"  | jq -Rs .)" \
  | bao kv put "oh/wifi/$SLUG" - >/dev/null || die "failed writing oh/wifi/$SLUG"

bao kv metadata put \
  -custom-metadata="ssid=$SSID" \
  -custom-metadata="hosts=${HOSTS:--}" \
  -custom-metadata="imported_at=$NOW" \
  "oh/wifi/$SLUG" >/dev/null || die "failed writing metadata for oh/wifi/$SLUG"

echo "  ok: oh/wifi/$SLUG  (ssid '$SSID')"
echo "  verify with: oh-cred wifi-list"
