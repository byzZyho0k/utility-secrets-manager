# oh-cred

A credential broker for Open Horizon fleets, built so that **people and AI coding
agents can use secrets without ever seeing them.**

`oh-cred` fetches a credential from a vault and injects it into a command's
environment. The secret is never printed, never written to disk, and never passed
as a command-line argument — so it cannot end up in terminal scrollback, an agent
transcript, a log file, or `ps` output.

```bash
oh-cred run edge1 myorg admin -- hzn exchange node list -o myorg
```

## The one-paragraph version

Open Horizon credentials tend to sprawl into `*.env` files, `/etc/environment`,
`~/.bashrc`, and container environments. Nothing in a credential records *which
exchange it belongs to*, so copies drift between hubs and fail with `401` — which
looks identical to an expired password. Meanwhile any tool that needs a secret
has to go hunting for it, and hunting is how secrets get printed. `oh-cred` fixes
both halves: secrets live in one vault under a schema **keyed by hub**, and the
only sanctioned way to use one is a command that injects it into a child process.

## Why it exists

This tool was extracted from a real cleanup of a small multi-hub fleet. Every
design decision traces to something that actually went wrong:

| What happened | What prevents it now |
|---|---|
| Six files all said `myorg/admin`; none said which hub. Copies on the wrong host returned `401` and were misdiagnosed as expired — then deleted. | Paths are **hub-first**. A credential cannot be separated from its exchange. |
| A password rotated; nothing noticed for three months, until a `401` that looked like an unrelated problem. | `verify-all` authenticates every credential against the exchange it records, wired into the fleet health check. |
| A redaction regex missed, and a live credential printed into an AI agent's transcript. | There is **no mode that prints a secret**. Injection is the only path. |
| With no documented way to get a credential, tooling improvised — reading `*.env`, `/etc/environment`, `docker inspect`. | One documented command. Agents are told to use it and to stop rather than improvise. |
| Files that looked like redundant copies held unique, live secrets and were nearly deleted. | Import-then-verify workflow; deletion only after retrieval is proven. |

The full account is in [docs/RATIONALE.md](docs/RATIONALE.md).

## What it is not

- **Not a password manager for humans to browse.** It has no "show me the value"
  command, on purpose. If you need to read a secret with your eyes, log into the
  vault directly with an admin policy.
- **Not a vault.** It is a thin, opinionated client over
  [OpenBao](https://openbao.org) (or HashiCorp Vault). The vault does the storage,
  encryption, policy, and audit.
- **Not Open Horizon specific in principle.** The pattern — inject, never print;
  key by the system the credential authenticates against — generalises. The
  current implementation speaks `HZN_*` environment variables.

## Documentation

| Document | Covers |
|---|---|
| [docs/RATIONALE.md](docs/RATIONALE.md) | The failure modes this exists to prevent, with the incidents behind them |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Path schema, auth model, design decisions and their tradeoffs |
| [docs/INSTALL.md](docs/INSTALL.md) | Standing up the vault and the tool from scratch |
| [docs/USAGE.md](docs/USAGE.md) | Day-to-day use, and how to grant an AI agent scoped access |

## Status

Working and in production on one fleet. Not yet packaged, tested, or versioned —
`bin/oh-cred` is a single Bash script. See [Roadmap](#roadmap).

## Roadmap

- [ ] Test suite (the verification paths especially — they gate deletions)
- [ ] `oh-cred rotate` — generate, set upstream, store, verify, in one step
- [ ] Structured output (`--json`) for scripted consumers
- [ ] Vault-agnostic backend so HashiCorp Vault works unmodified
- [ ] Package (`.deb`) and a systemd timer for scheduled `verify-all`
- [ ] Generalise beyond `HZN_*` to arbitrary variable mappings
