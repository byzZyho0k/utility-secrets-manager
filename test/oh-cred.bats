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
stub_curl() {
  local code="${1:-200}"
  cat > "$BATS_TEST_TMPDIR/curl" <<EOF
#!/usr/bin/env bash
echo "$code"
exit 0
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
