#!/usr/bin/env bats
# Tests for scripts/transfer.sh.
#
# Both vaults are a single stub `bao` that decides which side it is speaking for
# by looking at BAO_ADDR — the same signal the script itself uses.  Source
# contents are fixture files; destination writes are recorded, so a test can
# assert exactly what crossed, including the secret payload on stdin.
#
# Requires: bats-core  (brew install bats-core)

SCRIPT="$BATS_TEST_DIRNAME/../scripts/transfer.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_esc() { printf '%s' "$1" | tr / _; }

# A secret that exists on the source.  src_secret <path> [json-data]
src_secret() {
  local p="$1" data="${2:-{\"username\":\"admin\",\"password\":\"s3cr3t\"}}"
  mkdir -p "$SRC/data"
  printf '{"data":{"data":%s}}' "$data" > "$SRC/data/$(_esc "$p")"
}

# A secret that exists but whose current version has no data (soft-deleted).
src_deleted() {
  mkdir -p "$SRC/data"
  printf '{"data":{"data":null}}' > "$SRC/data/$(_esc "$1")"
}

# src_meta <path> <custom-metadata-json>
src_meta() {
  mkdir -p "$SRC/meta"
  printf '{"data":{"custom_metadata":%s}}' "$2" > "$SRC/meta/$(_esc "$1")"
}

# src_list <path> <json-array>
src_list() {
  mkdir -p "$SRC/list"
  printf '%s' "$2" > "$SRC/list/$(_esc "$1")"
}

# A secret that already exists on the destination.
dst_secret() {
  mkdir -p "$DST/data"
  printf '{"data":{"data":{"username":"old","password":"old-pw"}}}' > "$DST/data/$(_esc "$1")"
}

# One hub with one credential, wired up end to end.
fixture_one_hub() {
  src_list oh/hubs '["hub-a/"]'
  src_list oh/hubs/hub-a/users '["myorg/"]'
  src_list oh/hubs/hub-a/users/myorg '["admin"]'
  src_secret oh/hubs/hub-a/meta '{"exchange_url":"https://a.example.com/v1"}'
  src_secret oh/hubs/hub-a/users/myorg/admin
  src_meta   oh/hubs/hub-a/users/myorg/admin '{"role":"org-admin","hub":"hub-a"}'
}

# Recorded destination calls, one per line.
dst_calls() { cat "$BATS_TEST_TMPDIR/calls" 2>/dev/null | grep '^dst ' || true; }

# Payload written to a destination path by `kv put`.
dst_put_body() { cat "$DST/put/$(_esc "$1")" 2>/dev/null || true; }

setup() {
  SRC="$BATS_TEST_TMPDIR/src"
  DST="$BATS_TEST_TMPDIR/dst"
  mkdir -p "$SRC" "$DST"

  export SRC_ADDR="https://src.invalid:8200"
  export DST_ADDR="https://dst.invalid:8200"
  export SRC_TOKEN="src-token"
  export DST_TOKEN="dst-token"
  unset DRY_RUN SKIP_EXISTING

  cat > "$BATS_TEST_TMPDIR/bao" <<EOF
#!/usr/bin/env bash
# Stub bao. Routes on BAO_ADDR, the same way transfer.sh addresses each vault.
esc() { printf '%s' "\$1" | tr / _; }

if [ "\${BAO_ADDR:-}" = "$SRC_ADDR" ]; then ROOT="$SRC"; SIDE=src; else ROOT="$DST"; SIDE=dst; fi
echo "\$SIDE \$*" >> "$BATS_TEST_TMPDIR/calls"

if [ "\$1" = token ] && [ "\$2" = lookup ]; then
  [ -f "\$ROOT/token-invalid" ] && exit 1
  exit 0
fi

if [ "\$1" = kv ] && [ "\$2" = get ] && [ "\$3" = -format=json ]; then
  f="\$ROOT/data/\$(esc "\$4")"
  [ -f "\$f" ] || exit 2
  cat "\$f"; exit 0
fi

if [ "\$1" = kv ] && [ "\$2" = list ] && [ "\$3" = -format=json ]; then
  f="\$ROOT/list/\$(esc "\$4")"
  [ -f "\$f" ] || exit 2
  cat "\$f"; exit 0
fi

if [ "\$1" = kv ] && [ "\$2" = metadata ] && [ "\$3" = get ] && [ "\$4" = -format=json ]; then
  f="\$ROOT/meta/\$(esc "\$5")"
  [ -f "\$f" ] || exit 2
  cat "\$f"; exit 0
fi

if [ "\$1" = kv ] && [ "\$2" = put ]; then
  [ -f "\$ROOT/fail-put" ] && exit 1
  mkdir -p "\$ROOT/put"
  cat > "\$ROOT/put/\$(esc "\$3")"
  exit 0
fi

if [ "\$1" = kv ] && [ "\$2" = metadata ] && [ "\$3" = put ]; then
  [ -f "\$ROOT/fail-metadata-put" ] && exit 1
  exit 0
fi

exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bao"
  export PATH="$BATS_TEST_TMPDIR:$PATH"
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

@test "exits 1 when a required variable is unset" {
  unset SRC_ADDR
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SRC_ADDR is not set"* ]]
}

@test "refuses when source and destination are the same vault" {
  export DST_ADDR="$SRC_ADDR"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"same vault"* ]]
}

@test "exits 1 when the source token is not valid" {
  touch "$SRC/token-invalid"
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SRC_TOKEN is not valid"* ]]
}

@test "exits 1 when the destination token is not valid" {
  touch "$DST/token-invalid"
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DST_TOKEN is not valid"* ]]
}

@test "exits 1 when the source has no hubs" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no hubs found"* ]]
}

# ---------------------------------------------------------------------------
# copying
# ---------------------------------------------------------------------------

@test "writes the credential payload to the destination" {
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(dst_put_body oh/hubs/hub-a/users/myorg/admin)" == *'"password":"s3cr3t"'* ]]
  [[ "$(dst_put_body oh/hubs/hub-a/users/myorg/admin)" == *'"username":"admin"'* ]]
}

@test "copies custom_metadata, which kv put does not carry" {
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  local calls; calls=$(dst_calls)
  [[ "$calls" == *"kv metadata put"*"-custom-metadata=role=org-admin"* ]]
  [[ "$calls" == *"-custom-metadata=hub=hub-a"* ]]
}

@test "copies hub meta so the destination has exchange URLs" {
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(dst_put_body oh/hubs/hub-a/meta)" == *"a.example.com"* ]]
}

@test "copies hub infra when it exists" {
  fixture_one_hub
  src_secret oh/hubs/hub-a/infra '{"db_password":"dbpw"}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"oh/hubs/hub-a/infra"* ]]
  [[ "$(dst_put_body oh/hubs/hub-a/infra)" == *"dbpw"* ]]
}

@test "does not fail when a hub has no infra path" {
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"FAILED"* ]]
}

@test "copies every org and user under a hub" {
  src_list oh/hubs '["hub-a/"]'
  src_list oh/hubs/hub-a/users '["myorg/","IBM/"]'
  src_list oh/hubs/hub-a/users/myorg '["admin","node1"]'
  src_list oh/hubs/hub-a/users/IBM '["agbot"]'
  src_secret oh/hubs/hub-a/users/myorg/admin
  src_secret oh/hubs/hub-a/users/myorg/node1
  src_secret oh/hubs/hub-a/users/IBM/agbot
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copied  oh/hubs/hub-a/users/myorg/admin"* ]]
  [[ "$output" == *"copied  oh/hubs/hub-a/users/myorg/node1"* ]]
  [[ "$output" == *"copied  oh/hubs/hub-a/users/IBM/agbot"* ]]
  [[ "$output" == *"copied 3"* ]]
}

@test "keeps same-named credentials from different hubs distinct" {
  src_list oh/hubs '["hub-a/","hub-b/"]'
  for h in hub-a hub-b; do
    src_list "oh/hubs/$h/users" '["myorg/"]'
    src_list "oh/hubs/$h/users/myorg" '["admin"]'
  done
  src_secret oh/hubs/hub-a/users/myorg/admin '{"username":"admin","password":"pw-a"}'
  src_secret oh/hubs/hub-b/users/myorg/admin '{"username":"admin","password":"pw-b"}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(dst_put_body oh/hubs/hub-a/users/myorg/admin)" == *"pw-a"* ]]
  [[ "$(dst_put_body oh/hubs/hub-b/users/myorg/admin)" == *"pw-b"* ]]
}

@test "limits the copy to hubs named on the command line" {
  src_list oh/hubs '["hub-a/","hub-b/"]'
  for h in hub-a hub-b; do
    src_list "oh/hubs/$h/users" '["myorg/"]'
    src_list "oh/hubs/$h/users/myorg" '["admin"]'
    src_secret "oh/hubs/$h/users/myorg/admin"
  done
  run bash "$SCRIPT" hub-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"hub-b"* ]]
  [[ "$output" != *"hub-a"* ]]
}

# ---------------------------------------------------------------------------
# safety
# ---------------------------------------------------------------------------

@test "never prints a secret value" {
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"s3cr3t"* ]]
}

@test "skips a soft-deleted secret rather than copying a null" {
  src_list oh/hubs '["hub-a/"]'
  src_list oh/hubs/hub-a/users '["myorg/"]'
  src_list oh/hubs/hub-a/users/myorg '["admin","ghost"]'
  src_secret  oh/hubs/hub-a/users/myorg/admin
  src_deleted oh/hubs/hub-a/users/myorg/ghost
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped oh/hubs/hub-a/users/myorg/ghost"* ]]
  [ -z "$(dst_put_body oh/hubs/hub-a/users/myorg/ghost)" ]
}

@test "dry run writes nothing to the destination" {
  fixture_one_hub
  DRY_RUN=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"would copy"* ]]
  [[ "$(dst_calls)" != *"kv put"* ]]
  [[ "$(dst_calls)" != *"kv metadata put"* ]]
}

@test "SKIP_EXISTING leaves a destination secret untouched" {
  fixture_one_hub
  dst_secret oh/hubs/hub-a/users/myorg/admin
  SKIP_EXISTING=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exists  oh/hubs/hub-a/users/myorg/admin"* ]]
  [ -z "$(dst_put_body oh/hubs/hub-a/users/myorg/admin)" ]
}

@test "without SKIP_EXISTING an existing destination secret is overwritten" {
  fixture_one_hub
  dst_secret oh/hubs/hub-a/users/myorg/admin
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$(dst_put_body oh/hubs/hub-a/users/myorg/admin)" == *"s3cr3t"* ]]
}

# ---------------------------------------------------------------------------
# failure reporting
# ---------------------------------------------------------------------------

@test "exits 1 and names the path when a write fails" {
  fixture_one_hub
  touch "$DST/fail-put"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"oh/hubs/hub-a/users/myorg/admin"* ]]
}

@test "exits 1 when the metadata write fails" {
  fixture_one_hub
  touch "$DST/fail-metadata-put"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"metadata"* ]]
}

@test "reports a count of what moved" {
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copied 2, skipped 0, failed 0"* ]]
}

@test "points at verify-all once the copy is done" {
  fixture_one_hub
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"oh-cred verify-all"* ]]
}
