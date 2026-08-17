# Usage

## The four commands

```bash
oh-cred list                                   # inventory — never shows secrets
oh-cred run <hub> <org> <user> -- <command>    # run command with HZN_* set
oh-cred verify <hub> <org> <user>              # test one credential against its own hub
oh-cred verify-all                             # test every stored credential
```

## Running commands

`run` is the workhorse. Everything after `--` executes with `HZN_ORG_ID`,
`HZN_EXCHANGE_USER_AUTH`, `HZN_EXCHANGE_URL`, and `HZN_FSS_CSSURL` set:

```bash
oh-cred run edge1 myorg admin -- hzn exchange node list -o myorg
oh-cred run edge1 root  root  -- hzn exchange org list
oh-cred run academy myorg admin -- hzn mms status
```

Wrap a whole script rather than exporting variables into your shell:

```bash
oh-cred run edge1 myorg admin -- ./hzn-css-sync.sh 2.32.0-1803
```

Need several commands? Wrap a shell, so the secret still dies with one process:

```bash
oh-cred run edge1 myorg admin -- bash -c '
  hzn exchange node list -o myorg
  hzn exchange service list -o myorg
'
```

### Acting on a different org

Some operations need a credential from one org acting on another. Override inside
the command and org-qualify the username **by expansion**, so the password is
never retyped:

```bash
oh-cred run edge1 root root -- bash -c '
  export HZN_ORG_ID=myorg
  export HZN_EXCHANGE_USER_AUTH="root/$HZN_EXCHANGE_USER_AUTH"
  hzn exchange node list -o myorg'
```

Prefer a credential whose org already matches the target — it avoids
qualification entirely.

## Verifying

```bash
$ oh-cred verify-all
  academy    myorg/admin          org-admin  OK (HTTP 200)
  edge1      IBM/admin            org-admin  OK (HTTP 200)
  edge1      myorg/admin          org-admin  OK (HTTP 200)
  edge1      root/root            superuser  OK (HTTP 200)
  unh        examples/joewxboy    org-user   OK (HTTP 200)
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
