# Architecture

## Components

```
┌──────────────┐   AppRole login (short-lived token)   ┌──────────────────┐
│   oh-cred    │ ───────────────────────────────────▶ │  OpenBao / Vault │
│  (Bash CLI)  │ ◀─────────────────────────────────── │  KV v2 at  oh/   │
└──────┬───────┘        credential + hub metadata      │  audit device    │
       │                                               └──────────────────┘
       │ HZN_* in the child's environment only
       ▼
  ┌──────────┐
  │ your cmd │  hzn, curl, a script, an agent's tool call
  └──────────┘
```

The vault does storage, encryption, policy, and audit. `oh-cred` is a thin client
whose entire job is to move a secret from the vault into a child process without
it touching anything durable in between.

## Path schema

```
oh/hubs/<hub>/meta                  exchange_url, css_url, agbot_url, fdo_url, subnet
oh/hubs/<hub>/users/<org>/<user>    username + password
oh/hubs/<hub>/infra                 hub provisioning secrets (DB, agbot, FDO, vault keys)
```

**Hub comes first, deliberately.** Org and user are not unique across a fleet —
two independent hubs commonly both have `myorg/admin`. Hub-first makes the
identifier globally unique and makes it impossible to request a credential
without stating which system it authenticates against. See RATIONALE §1.

### Secret data vs. metadata

Only the secret goes in the secret:

```json
{ "username": "admin", "password": "…" }
```

Everything descriptive lives in KV v2 **custom metadata**:

| Key | Purpose |
|---|---|
| `hub` | which deployment this belongs to |
| `org` | Open Horizon org |
| `exchange_url` | the endpoint this credential is expected to work against |
| `role` | `superuser`, `hub-admin`, `org-admin`, `node` — drives how `verify` tests it |
| `imported_at`, `verified_at` | provenance and freshness |

Keeping them separate means you can list, audit, and reason about the credential
inventory without ever reading a secret — `oh-cred list` needs metadata only.

`exchange_url` in metadata is what makes a credential **self-verifying**: the
thing it should authenticate against travels with it, so `verify` needs no
external configuration to test it.

## Auth model

| Consumer | Method | Policy | Scope |
|---|---|---|---|
| Human operator | userpass (or OIDC) | `human-admin` | full control of `oh/*` |
| Agent, hub A | AppRole | `llm-<hubA>-ro` | read-only, hub A only |
| Agent, hub B | AppRole | `llm-<hubB>-ro` | read-only, hub B only |
| Health check | AppRole | `fleet-verifier` | read-only, all hubs |

**One role per consumer.** Sharing a credential between tools makes revocation
all-or-nothing and makes the audit log useless — you learn that *something* read
a secret, not what. Separate roles make "designate this tool" and "revoke that
tool" single operations, and every audit entry names a role.

Tokens are short-lived (1h TTL, 4h max). The `role_id`/`secret_id` pair is the
long-lived bootstrap credential and is the one thing that must sit on disk;
it is scoped to exactly one policy, so its blast radius is that policy.

KV v2 splits data and metadata into separate API paths, so read-only policies
must name both:

```hcl
path "oh/data/hubs/<hub>/*"     { capabilities = ["read"] }
path "oh/metadata/hubs/<hub>/*" { capabilities = ["read","list"] }
```

## Design decisions, and what they cost

### No command prints a secret

The single most important property. Discussed at length in RATIONALE §3.

**Cost:** a human who genuinely needs to see a value must authenticate to the
vault separately. That friction is intentional — it makes reading a secret a
deliberate, audited act rather than a reflex.

### Injection via environment, not a file or an argument

`exec`ing the target command with `HZN_*` set means the secret exists in one
process's memory and dies with it.

**Cost:** environment variables are visible to the process itself and to root via
`/proc/<pid>/environ`. This defends against durable leaks (transcripts, logs,
files, `ps`), not against a compromised host. A vault client cannot defend
against root on the machine it runs on; nothing at this layer can.

### Verification uses HTTP status, not a parsed error

`verify` distinguishes:

| Code | Meaning |
|---|---|
| `200` | credential valid and authorised |
| `403` | credential **valid**, account lacks rights for that endpoint |
| `401` | credential rejected — the actual fault |
| `000` | endpoint unreachable — a network problem, not a credential problem |

Treating `403` as success matters: a node credential legitimately cannot read
admin endpoints, and reporting that as a credential failure would train people to
ignore the check.

### The vault is loopback-only

The listener binds `127.0.0.1` with TLS. Fleet operations run *from* the
workstation and reach hosts over SSH, so nothing needs to reach the vault across
the network.

**Cost:** hosts cannot fetch their own credentials directly. Exposing the vault
would require a real certificate, network policy, and a considered threat model —
worth doing deliberately, not by leaving the default `0.0.0.0` listener in place.

> Note: a packaged install may ship a self-signed certificate **without SANs**,
> which modern TLS stacks reject — pushing users toward `-tls-skip-verify` and
> silently discarding verification. Generate a certificate with proper SANs
> (`IP:127.0.0.1`, `DNS:localhost`) so verification actually works.

### Auto-unseal is opt-in, and a real tradeoff

Without it, the vault is sealed after a reboot and every credential operation
fails until a human supplies key shares. With it, shares live on the vault host,
so **root on that host means access to every credential**.

Neither is right in general:

- **Single-operator workstation with restricted physical access** → auto-unseal
  is reasonable; the machine's root already implies compromise of everything.
- **Shared, remote, or multi-tenant host** → do not. Use a KMS-backed seal or
  accept manual unsealing.

Whichever you choose, write down *which* you chose and why. An undocumented
auto-unseal is indistinguishable from an accident.

### Audit is fail-closed

If the audit device cannot write, the vault refuses requests. Correct — but it
makes disk space on the vault host an availability dependency. Monitor it, or run
a second audit device so one failing does not block the vault.

## Deletion workflow

Deleting plaintext credential files is the riskiest operation in a migration, and
gets an explicit gate (RATIONALE §5):

```
inventory → fingerprint (hash, never print) → import anything missing
          → verify-all must pass → shred
```

Fingerprinting with a hash lets you prove two files hold the same secret, or that
one is unique, without displaying either.
