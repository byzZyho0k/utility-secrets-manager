# Usage

## The commands

Exchange credentials — the original four:

```bash
oh-cred list                                   # inventory — never shows secrets
oh-cred run <hub> <org> <user> -- <command>    # run command with HZN_* set
oh-cred verify [--force] <hub> <org> <user>    # test one credential against its own hub
oh-cred verify-all                             # test every stored credential
oh-cred state                                  # open circuit breakers / back-offs
oh-cred reset <hub> [<org> <user>]             # clear breaker state
```

Seal material and wifi PSKs, which live outside the `oh/hubs/` tree and use their
own roles ([Seal material](#seal-material), [Wifi PSKs](#wifi-psks)):

```bash
oh-cred seal-list                              # hubs with stored seal material
oh-cred seal-status <hub>                      # is that hub's bao sealed?
oh-cred unseal <hub>                           # unseal it using the stored shares
oh-cred wifi-list                              # stored networks, slug → SSID
oh-cred wifi-run <slug> -- <command>           # run command with WIFI_SSID/WIFI_PSK
```

No command in either group prints a secret.

## Running commands

`run` is the workhorse. Everything after `--` executes with `HZN_ORG_ID`,
`HZN_EXCHANGE_USER_AUTH`, `HZN_EXCHANGE_URL`, and `HZN_FSS_CSSURL` set:

```bash
oh-cred run hub-a myorg admin -- hzn exchange node list -o myorg
oh-cred run hub-a root  root  -- hzn exchange org list
oh-cred run hub-b myorg admin -- hzn mms status
```

Wrap a whole script rather than exporting variables into your shell:

```bash
oh-cred run hub-a myorg admin -- ./hzn-css-sync.sh 2.32.0-1803
```

Need several commands? Wrap a shell, so the secret still dies with one process:

```bash
oh-cred run hub-a myorg admin -- bash -c '
  hzn exchange node list -o myorg
  hzn exchange service list -o myorg
'
```

### Acting on a different org

Some operations need a credential from one org acting on another. Override inside
the command and org-qualify the username **by expansion**, so the password is
never retyped:

```bash
oh-cred run hub-a root root -- bash -c '
  export HZN_ORG_ID=myorg
  export HZN_EXCHANGE_USER_AUTH="root/$HZN_EXCHANGE_USER_AUTH"
  hzn exchange node list -o myorg'
```

Prefer a credential whose org already matches the target — it avoids
qualification entirely.

## Verifying

```bash
$ oh-cred verify-all
  hub-a      acme/admin           org-admin  OK (HTTP 200)
  hub-a      myorg/admin          org-admin  OK (HTTP 200)
  hub-a      root/root            superuser  OK (HTTP 200)
  hub-b      myorg/admin          org-admin  OK (HTTP 200)
  hub-c      examples/alice       org-user   OK (HTTP 200)
```

| Result | Meaning | Action |
|---|---|---|
| `OK (200)` | valid and authorised | none |
| `OK (403)` | **valid**, lacks rights for that endpoint | none — normal for node credentials |
| `REJECTED (401)` | password wrong or account gone | rotate or remove |
| `UNREACHABLE` | endpoint down or unroutable | network problem, not a credential problem |

Exit is non-zero if anything failed, so it drops into a health check directly:

```bash
oh-cred verify-all || echo "credential problem — investigate"
```

Run it on a schedule. A credential that stops working is otherwise invisible
until something needs it, which is reliably the worst moment.

## Granting an AI agent access

This is what the tool is for. Three steps:

**1. Give the agent its own role.** Never share one with a human or another tool —
per-role scoping is what makes revocation and audit meaningful.

```bash
bao write auth/approle/role/llm-<hub>-ro \
  token_policies="llm-<hub>-ro" token_ttl=1h token_max_ttl=4h
```

**2. Scope it to the minimum.** A read-only policy for one hub. An agent working
on hub A should be structurally unable to read hub B's secrets — and you should
confirm that by testing the denial, not by reading the policy.

**3. Tell it the sanctioned path, and to stop rather than improvise.** Put this
in `CLAUDE.md`, `AGENTS.md`, or your agent's equivalent:

```markdown
## Credentials

All credentials live in Bao. Reach them only through `oh-cred`:

    oh-cred run <hub> <org> <user> -- <command>

`oh-cred run` injects the secret into the child process. It is never printed.
**There is deliberately no mode that displays a password** — that is the point of
the tool, not an oversight. Do not add a `--show` flag and do not work around it
with `bao kv get`.

Do not search for secrets in `*.env` files, `/etc/environment`, `docker inspect`,
or shell configs. If `oh-cred` cannot supply what you need, say so and stop.
```

That last instruction matters more than it looks. An agent with no sanctioned
path will invent one, and its improvisation optimises for *finding* the secret,
not for protecting it. See RATIONALE §4.

## When a credential fails

A refused credential is marked `suspect` and is **not** re-tested on later runs:

```
  unh   examples/joewxboy   -   SUSPECT (HTTP 401 since 2026-08-21T10:00:00Z, not retried)
```

It still counts as a fault wherever it is reported — it just stops generating
traffic. This matters because `unh-iol` deny-lists an IP after too many 4xx, and
a stale credential re-checked on every run is what earns the block. Once blocked
everything returns `000`, including the check that would have told you the
credential was stale.

```bash
oh-cred state                              # what breakers are open
oh-cred verify --force unh examples joewxboy   # re-test after fixing something
oh-cred reset unh examples joewxboy        # clear one credential's flag
oh-cred reset unh                          # clear a hub's flag and back-off
```

A hub that returns `000` is put in a back-off window — 6h by default, set
`OH_CRED_BLOCK_COOLDOWN` (seconds) to change it — during which its credentials
are skipped without a request.

**Do not "just check again" against a hub that is blocking you.** Repeated
probing is the cause, not the diagnostic.

## Seal material

A hub's own OpenBao seals on every restart (Shamir, file storage, no native
auto-unseal). Storing the shares here means a reboot is survivable and the key
is not sitting in `/tmp` on the host it protects.

```bash
oh-cred seal-list                # hubs with stored seal material (no secrets)
oh-cred seal-status edge1        # is that hub's bao sealed right now?
oh-cred unseal edge1             # unseal it using the stored shares
```

`unseal` checks the seal state *before* reading the key, so an already-open vault
costs no secret read and generates no audit entry for one. The share is POSTed on
stdin, never as an argument, and is never printed.

Storing material (human only — the AppRoles are read-only and cannot write):

```bash
bao login -method=userpass username=admin
bash scripts/import-seal.sh edge1 http://192.168.50.85:8200 /tmp/edge1-keys.json
shred -u /tmp/edge1-keys.json
```

## Wifi PSKs

```bash
oh-cred wifi-list                                   # slug → SSID, no secrets
oh-cred wifi-run pit-of-despair -- some-command     # WIFI_SSID / WIFI_PSK exported
```

Entries are keyed by a lowercase slug because real SSIDs contain spaces; the true
SSID rides in the secret, so the child process gets the exact string a supplicant
needs.

```bash
bao login -method=userpass username=admin
bash scripts/import-wifi.sh pit-of-despair 'Pit of Despair' 'rpi-*,edge1,edge2'
# prompts for the PSK; never takes it as an argument
```

## Anti-patterns

**Don't** capture the credential into your own shell:

```bash
export HZN_EXCHANGE_USER_AUTH=$(...)     # now it is in your shell, your history,
                                         # and every child process you spawn
```

**Don't** add a flag to print a value. If you want one, what you actually want is
an admin login to the vault — a separate, audited act.

**Don't** write a credential to a file "just for this script." Wrap the script in
`oh-cred run` instead.

**Don't** assume a `401` means expired. Check you are pointed at the hub the
credential belongs to. Two hubs with the same org names is the single most common
source of confusion in a multi-hub fleet, and this exact mistake has caused a
misdiagnosis and an unnecessary deletion. `oh-cred verify` reports the endpoint it
tested against for precisely this reason.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `AppRole login failed` | vault sealed (after a reboot, if auto-unseal is off), or the role file is unreadable |
| `cannot read oh/hubs/...` | the token's policy does not cover that hub — usually correct behaviour |
| Every command fails after a reboot | vault is sealed; unseal it or enable auto-unseal |
| `verify` says `UNREACHABLE` | the hub endpoint is down or unroutable — the credential is untested, not bad |
| Vault refuses all requests | audit device cannot write (fail-closed) — check disk space |

Check vault state:

```bash
BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/opt/openbao/tls/tls.crt bao status
```
