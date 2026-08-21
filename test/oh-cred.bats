#!/usr/bin/env bats
# Tests for bin/oh-cred.
#
# All tests run against a stub `bao` that never contacts a real vault, and a
# stub `curl` that returns configurable HTTP status codes.  The only real
# behaviour under test is the Bash logic inside bin/oh-cred itself.
#
# Requires: bats-core  (brew install bats-core)

SCRIPT="$BATS_TEST_DIRNAME/../bin/oh-cred"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a stub bao into the temp PATH for the current test.
# Usage: stub_bao [--kv-get-json <json>] [--kv-list-json <json>]
#                 [--metadata-json <json>] [--field <value>]
#                 [--login-fail] [--exit <n>]
stub_bao() {
  local kv_get_json='{"data":{"data":{"username":"testuser","password":"testpass"}}}'
  local kv_list_json='["hub-a/"]'
  local metadata_json='{"data":{"custom_metadata":{"role":"org-admin","verified_at":"2024-01-01"}}}'
  local field_val="https://exchange.example.com"
  local login_fail=0
  local exit_code=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kv-get-json)  kv_get_json="$2";  shift 2 ;;
      --kv-list-json) kv_list_json="$2"; shift 2 ;;
      --metadata-json) metadata_json="$2"; shift 2 ;;
      --field)        field_val="$2";    shift 2 ;;
      --login-fail)   login_fail=1;      shift   ;;
      --exit)         exit_code="$2";    shift 2 ;;
      *) shift ;;
    esac
  done

  cat > "$BATS_TEST_TMPDIR/bao" <<EOF
#!/usr/bin/env bash
# Stub bao for testing.

# Capture the full argument list for inspection.
echo "\$*" >> "$BATS_TEST_TMPDIR/bao.calls"

if [[ "\$1" == "write" && "\$2" == "-field=token" ]]; then
  if [[ "$login_fail" -eq 1 ]]; then exit 1; fi
  echo "stub-token"
  exit 0
fi

if [[ "\$1" == "kv" && "\$2" == "get" && "\$3" == "-field="* ]]; then
  echo "$field_val"
  exit $exit_code
fi

if [[ "\$1" == "kv" && "\$2" == "get" && "\$3" == "-format=json" ]]; then
  echo '$kv_get_json'
  exit $exit_code
fi

if [[ "\$1" == "kv" && "\$2" == "list" && "\$3" == "-format=json" ]]; then
  echo '$kv_list_json'
  exit $exit_code
fi

if [[ "\$1" == "kv" && "\$2" == "metadata" && "\$3" == "get" && "\$4" == "-format=json" ]]; then
  echo '$metadata_json'
  exit $exit_code
fi

exit $exit_code
EOF
  chmod +x "$BATS_TEST_TMPDIR/bao"
  export PATH="$BATS_TEST_TMPDIR:$PATH"
}

# Write a stub curl that emits a configurable HTTP status code.
#
# Second arg is curl's exit status. This matters: when curl cannot connect it
# writes "000" via -w AND exits non-zero (7). A stub that always exits 0 hides
# the bug where `$(curl ... || echo 000)` concatenates into "000000" and never
# matches the 000 case. Default the failure path to a realistic exit 7.
stub_curl() {
  local code="${1:-200}" rc="${2:-}"
  if [ -z "$rc" ]; then
    if [ "$code" = "000" ]; then rc=7; else rc=0; fi
  fi
  cat > "$BATS_TEST_TMPDIR/curl" <<EOF
#!/usr/bin/env bash
echo "REQ \$*" >> "$BATS_TEST_TMPDIR/curl.reqs"
echo "$code"
exit $rc
EOF
  chmod +x "$BATS_TEST_TMPDIR/curl"
  export PATH="$BATS_TEST_TMPDIR:$PATH"
}

# Write a stub AppRole env file into BATS_TEST_TMPDIR.
write_approle_env() {
  local name="${1:-fleet-verifier}"
  local dir="$BATS_TEST_TMPDIR/approle"
  mkdir -p "$dir"
  printf 'ROLE_ID=test-role-id\nSECRET_ID=test-secret-id\n' > "$dir/$name.env"
  export OH_CRED_APPROLE_DIR="$dir"
}

setup() {
  # Each test gets a fresh tmp dir already set by bats.
  # Wipe any leftover call log.
  rm -f "$BATS_TEST_TMPDIR/bao.calls"
  # Circuit-breaker state MUST be per-test. Without this the suite writes into
  # the developer's real ~/.local/state/oh-cred and tests contaminate each other
  # (the 401 test trips the breaker, then the 200 test is skipped).
  export OH_CRED_STATE_DIR="$BATS_TEST_TMPDIR/state"
  # Point at a non-existent vault so accidental real calls fail immediately.
  export BAO_ADDR="https://127.0.0.1:19999"
  export BAO_CACERT="/dev/null"
  unset BAO_TOKEN
}

# ---------------------------------------------------------------------------
# help / usage
# ---------------------------------------------------------------------------

@test "no args prints usage" {
  stub_bao
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"oh-cred"* ]]
  [[ "$output" == *"run"* ]]
}

@test "--help prints usage" {
  stub_bao
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"oh-cred"* ]]
}

@test "-h prints usage" {
  stub_bao
  run "$SCRIPT" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"oh-cred"* ]]
}

@test "unknown subcommand exits 1 with helpful message" {
  stub_bao
  run "$SCRIPT" bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown subcommand"* ]]
  [[ "$output" == *"bogus"* ]]
}

# ---------------------------------------------------------------------------
# missing dependency
# ---------------------------------------------------------------------------

@test "exits 1 when bao is not installed" {
  # Source the script with a restricted PATH so bao is not found.
  # We test by invoking bash directly (bypassing /usr/bin/env) with an empty PATH.
  local emptydir="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$emptydir"
  # bash itself is known; pass it explicitly so /usr/bin/env bash still resolves.
  run /bin/bash -c "export PATH=\"$emptydir\"; source $SCRIPT" 2>&1 || true
  # The script should have printed the error and the exit code should be 1.
  [[ "$output" == *"bao not installed"* ]]
}

# ---------------------------------------------------------------------------
# run — argument validation
# ---------------------------------------------------------------------------

@test "run exits 1 with too few arguments" {
  stub_bao
  run "$SCRIPT" run hub-a myorg
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
}

@test "run exits 1 when -- separator is missing" {
  stub_bao
  run "$SCRIPT" run hub-a myorg admin true
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected --"* ]]
}

@test "run exits 1 when no command follows --" {
  stub_bao
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" run hub-a myorg admin --
  [ "$status" -eq 1 ]
  [[ "$output" == *"no command given"* ]]
}

# ---------------------------------------------------------------------------
# run — environment injection
# ---------------------------------------------------------------------------

@test "run sets HZN_EXCHANGE_USER_AUTH for child process" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"s3cr3t"}}}' \
    --field "https://exchange.example.com"
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" run hub-a myorg admin -- env
  [ "$status" -eq 0 ]
  [[ "$output" == *"HZN_EXCHANGE_USER_AUTH=admin:s3cr3t"* ]]
}

@test "run sets HZN_ORG_ID for child process" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"s3cr3t"}}}'
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" run hub-a myorg admin -- env
  [ "$status" -eq 0 ]
  [[ "$output" == *"HZN_ORG_ID=myorg"* ]]
}

@test "run sets HZN_EXCHANGE_URL for child process" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"pass"}}}' \
    --field "https://hub-a.example.com/v1"
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" run hub-a myorg admin -- env
  [ "$status" -eq 0 ]
  [[ "$output" == *"HZN_EXCHANGE_URL=https://hub-a.example.com/v1"* ]]
}

@test "run does NOT print the password to stdout" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"topsecret"}}}'
  write_approle_env "llm-hub-a-ro"
  # Run a child that echoes its own env to stdout.
  run "$SCRIPT" run hub-a myorg admin -- env
  [ "$status" -eq 0 ]
  # The raw password must not appear as a standalone word outside the auth var.
  # We check that it only appears inside the expected var assignment, never bare.
  local bare_count
  bare_count=$(echo "$output" | grep -c '^topsecret$' || true)
  [ "$bare_count" -eq 0 ]
}

@test "run uses BAO_TOKEN when set, skipping approle file" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"pass"}}}'
  export BAO_TOKEN="human-token"
  # No approle file written — if the script tries to read one it will die().
  run "$SCRIPT" run hub-a myorg admin -- true
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# verify — HTTP status interpretation
# ---------------------------------------------------------------------------

@test "verify exits 0 and prints OK for HTTP 200" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"pass"}}}' \
    --metadata-json '{"data":{"custom_metadata":{"role":"org-admin"}}}'
  stub_curl 200
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" verify hub-a myorg admin
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "verify exits 0 and prints OK for HTTP 403 (valid credential, no rights)" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"nodeuser","password":"pass"}}}' \
    --metadata-json '{"data":{"custom_metadata":{"role":"node"}}}'
  stub_curl 403
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" verify hub-a myorg nodeuser
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "verify exits 1 and prints REJECTED for HTTP 401" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"wrong"}}}' \
    --metadata-json '{"data":{"custom_metadata":{"role":"org-admin"}}}'
  stub_curl 401
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" verify hub-a myorg admin
  [ "$status" -eq 1 ]
  [[ "$output" == *"REJECTED"* ]]
}

@test "verify exits 2 and prints UNREACHABLE for curl returning 000" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"pass"}}}' \
    --metadata-json '{"data":{"custom_metadata":{"role":"org-admin"}}}'
  stub_curl 000
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" verify hub-a myorg admin
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNREACHABLE"* ]]
}

@test "verify exits 1 for unexpected HTTP status (e.g. 500)" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"pass"}}}' \
    --metadata-json '{"data":{"custom_metadata":{"role":"org-admin"}}}'
  stub_curl 500
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" verify hub-a myorg admin
  [ "$status" -eq 1 ]
  [[ "$output" == *"500"* ]]
}

@test "verify exits 1 with usage message when called with wrong arg count" {
  stub_bao
  run "$SCRIPT" verify hub-a myorg
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
}

# ---------------------------------------------------------------------------
# verify — node role uses a different endpoint
# ---------------------------------------------------------------------------

@test "verify uses node endpoint path for role=node" {
  stub_bao \
    --kv-get-json '{"data":{"data":{"username":"node01","password":"pass"}}}' \
    --metadata-json '{"data":{"custom_metadata":{"role":"node"}}}'
  stub_curl 200

  # Replace the stub curl with one that records the URL it was given.
  cat > "$BATS_TEST_TMPDIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$BATS_TEST_TMPDIR/curl.calls"
# Return the status code that the -w format string requests.
echo "200"
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/curl"

  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" verify hub-a myorg node01
  [ "$status" -eq 0 ]
  # The URL sent to curl should contain /nodes/, not /users/
  grep -q "/nodes/" "$BATS_TEST_TMPDIR/curl.calls"
}

# ---------------------------------------------------------------------------
# AppRole fallback
# ---------------------------------------------------------------------------

@test "exits 1 when AppRole login fails" {
  stub_bao --login-fail
  write_approle_env "llm-hub-a-ro"
  run "$SCRIPT" run hub-a myorg admin -- true
  [ "$status" -eq 1 ]
  [[ "$output" == *"AppRole login failed"* ]]
}

@test "exits 1 when approle env file is missing and BAO_TOKEN unset" {
  stub_bao
  export OH_CRED_APPROLE_DIR="$BATS_TEST_TMPDIR/nonexistent"
  run "$SCRIPT" run hub-a myorg admin -- true
  [ "$status" -eq 1 ]
  [[ "$output" == *"configured"* ]] || [[ "$output" == *"cannot read"* ]]
}

# ---------------------------------------------------------------------------
# verify-all — aggregate exit code
# ---------------------------------------------------------------------------

@test "verify-all exits 0 when every credential passes" {
  # Hub list returns one hub; user list returns one credential.
  stub_bao \
    --kv-list-json '["hub-a/"]' \
    --kv-get-json '{"data":{"data":{"username":"admin","password":"pass"}}}' \
    --metadata-json '{"data":{"custom_metadata":{"role":"org-admin"}}}'
  stub_curl 200
  write_approle_env "fleet-verifier"
  # list returns a single hub; the nested list needs to also return the right shape.
  # Rewrite the stub so each bao invocation returns sensibly shaped data.
  cat > "$BATS_TEST_TMPDIR/bao" <<'BAOSTUB'
#!/usr/bin/env bash
echo "$*" >> "$BATS_TEST_TMPDIR/bao.calls"
case "$*" in
  "write -field=token auth/approle/login "*)
    echo "stub-token"; exit 0 ;;
  "kv list -format=json oh/hubs")
    echo '["hub-a/"]'; exit 0 ;;
  "kv list -format=json oh/hubs/hub-a/users")
    echo '["myorg/"]'; exit 0 ;;
  "kv list -format=json oh/hubs/hub-a/users/myorg")
    echo '["admin"]'; exit 0 ;;
  "kv get -format=json oh/hubs/hub-a/users/myorg/admin")
    echo '{"data":{"data":{"username":"admin","password":"pass"}}}'; exit 0 ;;
  "kv get -field=exchange_url oh/hubs/hub-a/meta")
    echo "https://exchange.example.com"; exit 0 ;;
  "kv get -field=css_url oh/hubs/hub-a/meta")
    echo "https://css.example.com"; exit 0 ;;
  "kv metadata get -format=json oh/hubs/hub-a/users/myorg/admin")
    echo '{"data":{"custom_metadata":{"role":"org-admin","verified_at":"never"}}}'; exit 0 ;;
  *) exit 0 ;;
esac
BAOSTUB
  chmod +x "$BATS_TEST_TMPDIR/bao"
  write_approle_env "fleet-verifier"
  run "$SCRIPT" verify-all
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# seal material  (oh/seal/<hub>)
# ---------------------------------------------------------------------------

# A curl stub that can answer both shapes cmd_unseal uses: a JSON GET of
# /sys/seal-status, and a PUT to /sys/unseal reported via -w '%{http_code}'.
stub_curl_seal() {
  local sealed="${1:-true}" code="${2:-200}" sealed_after="${3:-false}"
  cat > "$BATS_TEST_TMPDIR/curl" <<EOF
#!/usr/bin/env bash
args="\$*"
# The unseal PUT: consume stdin so the key never lands anywhere, echo the code.
if [[ "\$args" == *"-w"* ]]; then
  cat >"$BATS_TEST_TMPDIR/unseal.body" 2>/dev/null || true
  echo "$code"
  echo "PUT" >> "$BATS_TEST_TMPDIR/curl.calls"
  exit 0
fi
# seal-status GET. First call reports \$sealed, later calls \$sealed_after.
if [[ -f "$BATS_TEST_TMPDIR/status.seen" ]]; then
  echo '{"initialized":true,"sealed":$sealed_after,"t":1,"progress":0}'
else
  touch "$BATS_TEST_TMPDIR/status.seen"
  echo '{"initialized":true,"sealed":$sealed,"t":1,"progress":0}'
fi
exit 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/curl"
  export PATH="$BATS_TEST_TMPDIR:$PATH"
}

write_seal_approle() {
  local dir="$BATS_TEST_TMPDIR/approle"
  mkdir -p "$dir"
  printf 'ROLE_ID=seal-role\nSECRET_ID=seal-secret\n' > "$dir/seal-operator.env"
  printf 'ROLE_ID=wifi-role\nSECRET_ID=wifi-secret\n' > "$dir/wifi-reader.env"
  export OH_CRED_APPROLE_DIR="$dir"
}

@test "seal-status exits 1 with usage when arg count is wrong" {
  stub_bao; write_seal_approle
  run "$SCRIPT" seal-status
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: oh-cred seal-status <hub>"* ]]
}

@test "unseal exits 1 with usage when arg count is wrong" {
  stub_bao; write_seal_approle
  run "$SCRIPT" unseal
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: oh-cred unseal <hub>"* ]]
}

@test "seal-status reports sealed state without printing any secret" {
  stub_bao --metadata-json '{"data":{"custom_metadata":{"bao_addr":"http://h:8200"}}}'
  write_seal_approle
  stub_curl_seal true
  run "$SCRIPT" seal-status edge1
  [ "$status" -eq 0 ]
  [[ "$output" == *"sealed=true"* ]]
  [[ "$output" != *"unseal_keys_b64"* ]]
}

@test "unseal is a no-op when the vault is already unsealed" {
  stub_bao --metadata-json '{"data":{"custom_metadata":{"bao_addr":"http://h:8200"}}}'
  write_seal_approle
  stub_curl_seal false
  run "$SCRIPT" unseal edge1
  [ "$status" -eq 0 ]
  [[ "$output" == *"already unsealed"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/curl.calls" ]
}

@test "unseal submits the key and reports UNSEALED" {
  stub_bao --metadata-json '{"data":{"custom_metadata":{"bao_addr":"http://h:8200"}}}' \
           --kv-get-json '{"data":{"data":{"unseal_keys_b64":["c3VwZXJzZWNyZXQ="]}}}'
  write_seal_approle
  stub_curl_seal true 200 false
  run "$SCRIPT" unseal edge1
  [ "$status" -eq 0 ]
  [[ "$output" == *"UNSEALED"* ]]
}

@test "unseal does NOT print the unseal key" {
  stub_bao --metadata-json '{"data":{"custom_metadata":{"bao_addr":"http://h:8200"}}}' \
           --kv-get-json '{"data":{"data":{"unseal_keys_b64":["c3VwZXJzZWNyZXQ="]}}}'
  write_seal_approle
  stub_curl_seal true 200 false
  run "$SCRIPT" unseal edge1
  [[ "$output" != *"c3VwZXJzZWNyZXQ="* ]]
}

@test "unseal reports failure when the vault rejects the key" {
  stub_bao --metadata-json '{"data":{"custom_metadata":{"bao_addr":"http://h:8200"}}}' \
           --kv-get-json '{"data":{"data":{"unseal_keys_b64":["YmFk"]}}}'
  write_seal_approle
  stub_curl_seal true 400 true
  run "$SCRIPT" unseal edge1
  [ "$status" -eq 1 ]
  [[ "$output" == *"rejected"* ]]
}

@test "unseal exits 1 when no seal material is stored" {
  stub_bao --metadata-json '{"data":{"custom_metadata":{"bao_addr":"http://h:8200"}}}' \
           --kv-get-json '{"data":{"data":{}}}'
  write_seal_approle
  stub_curl_seal true
  run "$SCRIPT" unseal edge1
  [ "$status" -eq 1 ]
  [[ "$output" == *"no unseal_keys_b64"* ]]
}

@test "seal commands use seal-operator role, not the per-hub read-only role" {
  stub_bao --metadata-json '{"data":{"custom_metadata":{"bao_addr":"http://h:8200"}}}'
  write_seal_approle
  stub_curl_seal false
  run "$SCRIPT" seal-status edge1
  [ "$status" -eq 0 ]
  grep -q "role_id=seal-role" "$BATS_TEST_TMPDIR/bao.calls"
  ! grep -q "test-role-id" "$BATS_TEST_TMPDIR/bao.calls"
}

# ---------------------------------------------------------------------------
# wifi PSKs  (oh/wifi/<slug>)
# ---------------------------------------------------------------------------

@test "wifi-run exits 1 when -- separator is missing" {
  stub_bao; write_seal_approle
  run "$SCRIPT" wifi-run home-net echo hi
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected -- before the command"* ]]
}

@test "wifi-run exits 1 when no command follows --" {
  stub_bao; write_seal_approle
  run "$SCRIPT" wifi-run home-net --
  [ "$status" -eq 1 ]
}

@test "wifi-run exports WIFI_SSID and WIFI_PSK to the child" {
  stub_bao --kv-get-json '{"data":{"data":{"ssid":"Pit of Despair","psk":"hunter2secret"}}}'
  write_seal_approle
  run "$SCRIPT" wifi-run pit-of-despair -- /bin/sh -c 'echo "$WIFI_SSID|$WIFI_PSK"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pit of Despair|hunter2secret"* ]]
}

@test "wifi-run does NOT print the psk when the child does not ask for it" {
  stub_bao --kv-get-json '{"data":{"data":{"ssid":"Pit of Despair","psk":"hunter2secret"}}}'
  write_seal_approle
  run "$SCRIPT" wifi-run pit-of-despair -- /bin/sh -c 'echo done'
  [ "$status" -eq 0 ]
  [[ "$output" != *"hunter2secret"* ]]
}

@test "wifi-run falls back to the slug when no ssid field is stored" {
  stub_bao --kv-get-json '{"data":{"data":{"psk":"pw"}}}'
  write_seal_approle
  run "$SCRIPT" wifi-run somenet -- /bin/sh -c 'echo "$WIFI_SSID"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"somenet"* ]]
}

@test "wifi-run exits 1 when the entry has no psk" {
  stub_bao --kv-get-json '{"data":{"data":{"ssid":"x"}}}'
  write_seal_approle
  run "$SCRIPT" wifi-run somenet -- /bin/sh -c 'echo hi'
  [ "$status" -eq 1 ]
  [[ "$output" == *"has no psk"* ]]
}

@test "wifi commands use the wifi-reader role" {
  stub_bao --kv-get-json '{"data":{"data":{"ssid":"n","psk":"p"}}}'
  write_seal_approle
  run "$SCRIPT" wifi-run somenet -- /bin/true
  grep -q "role_id=wifi-role" "$BATS_TEST_TMPDIR/bao.calls"
}

# ---------------------------------------------------------------------------
# circuit breaker  (the unh-iol deny-list problem)
#
# unh-iol deny-lists an IP after too many 4xx. A stale credential re-verified on
# every run supplies exactly that, and the resulting block then masks the
# credential state. The breaker must stop the *traffic* while keeping the alarm.
# ---------------------------------------------------------------------------

@test "curl returning 000 yields exactly 000, not the doubled 000000" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 000 7
  run "$SCRIPT" verify hub-a myorg admin
  [[ "$output" != *"000000"* ]]
  [[ "$output" == *"UNREACHABLE"* ]]
  [ "$status" -eq 2 ]
}

@test "a 401 marks the credential suspect" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 401
  run "$SCRIPT" verify hub-a myorg admin
  [ "$status" -eq 1 ]
  grep -q '"status":"suspect"' "$BATS_TEST_TMPDIR/state/verify-state.json"
}

@test "a suspect credential is reported but NOT re-requested" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 401
  run "$SCRIPT" verify hub-a myorg admin        # trips the breaker
  rm -f "$BATS_TEST_TMPDIR/curl.reqs"
  run "$SCRIPT" verify hub-a myorg admin        # second run
  [ "$status" -eq 1 ]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" == *"not retried"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/curl.reqs" ]        # the key property: no traffic
}

@test "--force re-requests despite an open breaker" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 401
  run "$SCRIPT" verify hub-a myorg admin
  rm -f "$BATS_TEST_TMPDIR/curl.reqs"
  run "$SCRIPT" verify --force hub-a myorg admin
  [ -f "$BATS_TEST_TMPDIR/curl.reqs" ]
}

@test "a later success clears the suspect flag" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 401
  run "$SCRIPT" verify hub-a myorg admin
  stub_curl 200
  run "$SCRIPT" verify --force hub-a myorg admin
  [ "$status" -eq 0 ]
  run grep -c '"status":"suspect"' "$BATS_TEST_TMPDIR/state/verify-state.json"
  [ "$status" -ne 0 ]
}

@test "an unreachable hub puts the whole hub in cooldown, skipping later checks" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 000 7
  run "$SCRIPT" verify hub-a myorg admin
  [ "$status" -eq 2 ]
  rm -f "$BATS_TEST_TMPDIR/curl.reqs"
  run "$SCRIPT" verify hub-a myorg admin
  [ "$status" -eq 3 ]
  [[ "$output" == *"SKIPPED (hub unreachable"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/curl.reqs" ]
}

@test "cooldown of 0 lets the hub be probed again immediately" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 000 7
  run "$SCRIPT" verify hub-a myorg admin
  export OH_CRED_BLOCK_COOLDOWN=0
  rm -f "$BATS_TEST_TMPDIR/curl.reqs"
  run "$SCRIPT" verify hub-a myorg admin
  [ -f "$BATS_TEST_TMPDIR/curl.reqs" ]
}

@test "state lists open breakers without printing any secret" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 401
  run "$SCRIPT" verify hub-a myorg admin
  run "$SCRIPT" state
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUSPECT"* ]]
  [[ "$output" != *"testpass"* ]]
}

@test "reset clears a suspect credential" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 401
  run "$SCRIPT" verify hub-a myorg admin
  run "$SCRIPT" reset hub-a myorg admin
  [ "$status" -eq 0 ]
  rm -f "$BATS_TEST_TMPDIR/curl.reqs"
  run "$SCRIPT" verify hub-a myorg admin
  [ -f "$BATS_TEST_TMPDIR/curl.reqs" ]
}

@test "reset with just a hub clears its cooldown and its credentials" {
  stub_bao; write_approle_env llm-hub-a-ro; stub_curl 000 7
  run "$SCRIPT" verify hub-a myorg admin
  run "$SCRIPT" reset hub-a
  [ "$status" -eq 0 ]
  run "$SCRIPT" state
  [[ "$output" != *"BLOCKED"* ]]
}

@test "verify-all reports a fault ahead of unreachability" {
  stub_bao; write_approle_env fleet-verifier; stub_curl 401
  run "$SCRIPT" verify-all
  [ "$status" -eq 1 ]
}
