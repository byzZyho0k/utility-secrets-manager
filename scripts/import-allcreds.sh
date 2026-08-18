#!/usr/bin/env bash
# scripts/import-allcreds.sh — one-shot import of ~/allcreds.env into Bao.
#
# Reads credentials from ALLCREDS (default ~/allcreds.env), writes them to the
# oh/hubs/<hub>/users/<org>/<user> path schema, and writes hub metadata to
# oh/hubs/<hub>/meta.  Never prints a secret value to stdout.
#
# Usage:
#   export BAO_ADDR=https://127.0.0.1:8200
#   export BAO_CACERT=/opt/homebrew/etc/openbao/tls/tls.crt
#   bash scripts/import-allcreds.sh
#
# The script is idempotent: re-running it creates a new KV v2 version of each
# secret but does not otherwise fail.
set -uo pipefail

die() { echo "import: $*" >&2; exit 1; }

ALLCREDS="${ALLCREDS:-$HOME/allcreds.env}"
[ -r "$ALLCREDS" ] || die "cannot read $ALLCREDS"

command -v bao >/dev/null || die "bao not installed"
bao token lookup >/dev/null 2>&1 \
  || die "no valid BAO_TOKEN — log in first: bao login -method=userpass username=admin"

# ---------------------------------------------------------------------------
# Hub definition — all non-secret
# ---------------------------------------------------------------------------
HUB="unh-iol"
EXCHANGE_URL="http://open-horizon.lfedge.iol.unh.edu:3090/v1"
CSS_URL="http://open-horizon.lfedge.iol.unh.edu:9443/"
AGBOT_URL="http://open-horizon.lfedge.iol.unh.edu:3111"
FDO_URL="http://open-horizon.lfedge.iol.unh.edu:9008/api"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---------------------------------------------------------------------------
# Step 1: write hub metadata (no secrets)
# ---------------------------------------------------------------------------
echo "→ Writing hub metadata for $HUB ..."
bao kv put "oh/hubs/$HUB/meta" \
  exchange_url="$EXCHANGE_URL" \
  css_url="$CSS_URL" \
  agbot_url="$AGBOT_URL" \
  fdo_url="$FDO_URL" \
  >/dev/null
echo "  ok: oh/hubs/$HUB/meta"

# ---------------------------------------------------------------------------
# write_cred <org> <role> <pw_var>
#
# allcreds.env structure: each block defines a unique PW/TOKEN variable and
# then redefines HZN_ORG_ID + HZN_EXCHANGE_USER_AUTH.  Because HZN_EXCHANGE_
# USER_AUTH is redefined six times we source the whole file and then re-source
# only up to the line that sets <pw_var> so we capture the HZN_* values
# belonging to that block.
#
# The username is embedded in HZN_EXCHANGE_USER_AUTH as "user:password".
# We split on ':' to get the username without ever printing the password.
# ---------------------------------------------------------------------------
write_cred() {
  local org="$1" role="$2" pw_var="$3"
  local path

  # Source in a subshell so no secrets touch this process's environment.
  (
    set -uo pipefail

    # Source only through the line that sets pw_var (inclusive) so that later
    # blocks' redefinitions of HZN_EXCHANGE_USER_AUTH don't overwrite this one.
    local tmp
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f $tmp" EXIT

    # Extract the 3-line block: pw_var, HZN_ORG_ID, HZN_EXCHANGE_USER_AUTH.
    # Start capturing at pw_var and stop (inclusive) at the next
    # HZN_EXCHANGE_USER_AUTH — which is always the third line of the block.
    awk "
      /^[[:space:]]*export ${pw_var}=/ { found=1 }
      found && /^[[:space:]]*export HZN_EXCHANGE_USER_AUTH=/ { print; exit }
      { if (found) print }
    " "$ALLCREDS" > "$tmp"

    # shellcheck disable=SC1090
    source "$tmp"

    local pw user
    pw="${!pw_var:-}"
    [ -n "$pw" ] || { echo "import: $pw_var empty in $ALLCREDS" >&2; exit 1; }

    # Username is before the colon in HZN_EXCHANGE_USER_AUTH
    user="${HZN_EXCHANGE_USER_AUTH%%:*}"
    [ -n "$user" ] || { echo "import: HZN_EXCHANGE_USER_AUTH empty for $pw_var" >&2; exit 1; }

    path="oh/hubs/$HUB/users/$org/$user"

    bao kv put "$path" username="$user" password="$pw" >/dev/null
    bao kv metadata put \
      -custom-metadata="hub=$HUB" \
      -custom-metadata="org=$org" \
      -custom-metadata="role=$role" \
      -custom-metadata="exchange_url=$EXCHANGE_URL" \
      -custom-metadata="imported_at=$NOW" \
      "$path" >/dev/null

    # Print the path (no secret) for the parent to display
    echo "$path role=$role"
  ) || die "failed to import credential for $pw_var"

  # The subshell printed path info on success; prefix it
  : # parent does nothing extra — output came from subshell
}

# ---------------------------------------------------------------------------
# Step 2: write each credential block
# allcreds.env order:
#   EXCHANGE_ROOT_PW       → root/root       superuser
#   EXCHANGE_HUB_ADMIN_PW  → root/hubadmin   hub-admin
#   EXCHANGE_SYSTEM_ADMIN_PW → IBM/admin     org-admin
#   AGBOT_TOKEN            → IBM/agbot        node
#   EXCHANGE_USER_ADMIN_PW → myorg/admin     org-admin
#   HZN_DEVICE_TOKEN       → myorg/node1      node
# ---------------------------------------------------------------------------
echo ""
echo "→ Writing credentials ..."

write_cred root  superuser  EXCHANGE_ROOT_PW
write_cred root  hub-admin  EXCHANGE_HUB_ADMIN_PW
write_cred IBM   org-admin  EXCHANGE_SYSTEM_ADMIN_PW
write_cred IBM   node       AGBOT_TOKEN
write_cred myorg org-admin  EXCHANGE_USER_ADMIN_PW
write_cred myorg node       HZN_DEVICE_TOKEN

echo ""
echo "Import complete.  Now run:"
echo "  oh-cred list"
echo "  oh-cred verify-all"
