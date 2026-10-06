# oh-cred

![License](https://img.shields.io/github/license/open-horizon-services/utility-secrets-manager)
![Contributors](https://img.shields.io/github/contributors/open-horizon-services/utility-secrets-manager)

A credential broker for Open Horizon fleets, built so that **people and AI coding
agents can use secrets without ever seeing them.**

`oh-cred` fetches a credential from a vault and injects it into a command's
environment. The secret is never printed, never written to disk, and never passed
as a command-line argument — so it cannot end up in terminal scrollback, an agent
transcript, a log file, or `ps` output.

```bash
oh-cred run hub-a myorg admin -- hzn exchange node list -o myorg
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
| A stale credential re-verified on every health-check run tripped a hub's 4xx deny list. Everything then returned `000` — including the check that would have revealed the stale credential. | A refused credential is marked `suspect` and not re-tried; unreachable hubs get a back-off window. The alarm stays, the traffic stops. |
| A redaction regex missed, and a live credential printed into an AI agent's transcript. | There is **no mode that prints a secret**. Injection is the only path. |
| With no documented way to get a credential, tooling improvised — reading `*.env`, `/etc/environment`, `docker inspect`. | One documented command. Agents are told to use it and to stop rather than improvise. |
| Files that looked like redundant copies held unique, live secrets and were nearly deleted. | Import-then-verify workflow; deletion only after retrieval is proven. |

The full account is in [docs/RATIONALE.md](docs/RATIONALE.md).

## What it holds

Three kinds of secret, in three separate trees:

| Tree | Holds | Commands |
|---|---|---|
| `oh/hubs/<hub>/…` | exchange credentials (org users, nodes) | `list`, `run`, `verify`, `verify-all` |
| `oh/seal/<hub>` | a hub's **own** OpenBao unseal shares + root token | `seal-list`, `seal-status`, `unseal` |
| `oh/wifi/<slug>` | wifi SSID + PSK | `wifi-list`, `wifi-run` |

They are separate trees rather than one, because the per-hub read-only role is a
wildcard (`oh/data/hubs/<hub>/*`). Anything filed under a hub is reachable by
every consumer that can already read that hub's passwords — which is fine for an
org password and emphatically not fine for a vault root token. See
[ARCHITECTURE](docs/ARCHITECTURE.md#why-seal-material-is-not-under-ohhubs).

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
| [docs/INSTALL.md](docs/INSTALL.md) | Standing up the vault and the tool from scratch, and moving it to another vault |
| [docs/USAGE.md](docs/USAGE.md) | Day-to-day use, and how to grant an AI agent scoped access |

## Status

Working and in production on one fleet. Not yet packaged, tested, or versioned —
`bin/oh-cred` is a single Bash script. See [Roadmap](#roadmap).

## Roadmap

- [x] Test suite (the verification paths especially — they gate deletions)
- [x] Seal material (`oh/seal/<hub>`) and wifi PSKs (`oh/wifi/<slug>`)
- [x] Circuit breaker on repeated 4xx (a hub that deny-lists on 4xx turns a stale
      credential into a self-concealing outage)
- [ ] Teach the Pi image builder to pull its PSK via `wifi-run` at burn time
      (deliberately deferred — the PSK is still plaintext in
      `utility-raspberry-pi-image-builder/network.yaml`)
- [ ] `oh-cred rotate` — generate, set upstream, store, verify, in one step
- [ ] Structured output (`--json`) for scripted consumers
- [ ] Vault-agnostic backend so HashiCorp Vault works unmodified
- [ ] Package (`.deb`) and a systemd timer for scheduled `verify-all`
- [ ] Generalise beyond `HZN_*` to arbitrary variable mappings

## Prerequisites and setup

**Management Hub:** [Install the Open Horizon Management Hub](https://open-horizon.github.io/quick-start) or have access to an existing hub. `oh-cred` uses the hub's exchange API for the `verify` and `verify-all` commands. You may also use a downstream commercial distribution such as IBM's Edge Application Manager.

**Edge Node or workstation:** You will need a machine running Linux or macOS with [OpenBao](https://openbao.org) (or HashiCorp Vault) reachable from the host. The `oh-cred` script requires `bash`, `curl`, and the `bao` (or `vault`) CLI.

**Optional utilities:** `jq` (for pretty-printing exchange responses), `hzn` (Open Horizon CLI, required for `verify` and `verify-all` subcommands), `bats` (for running the test suite).

### Initial configuration

Export your vault address and a token with read access to the `oh/` path:

```shell
export BAO_ADDR=https://vault.example.com:8200
export BAO_TOKEN=<your-token>
```

If you use a per-hub read-only policy, you can scope the token to a single hub:

```shell
export HZN_ORG_ID=<your-org>
```

## Installation

Clone the repository on the host where you want to run `oh-cred`:

```shell
git clone https://github.com/open-horizon-services/utility-secrets-manager.git
cd utility-secrets-manager
```

Copy (or symlink) the binary onto your `PATH`:

```shell
sudo cp bin/oh-cred /usr/local/bin/oh-cred
# or
sudo ln -s "$(pwd)/bin/oh-cred" /usr/local/bin/oh-cred
```

Confirm it is installed:

```shell
oh-cred --help
```

Run the test suite to confirm the installation is sound:

```shell
make test
```

## Usage

Inject a credential into a child process (the secret is never printed):

```shell
oh-cred run hub-a myorg admin -- hzn exchange node list -o myorg
```

List all credentials stored for a hub:

```shell
oh-cred list hub-a
```

Verify every credential against its exchange:

```shell
oh-cred verify-all
```

Check the status of seal material for a hub:

```shell
oh-cred seal-status hub-a
```

Run a command with a wifi PSK injected:

```shell
oh-cred wifi-run home-network -- nmcli device wifi connect HomeSSID
```

See [docs/USAGE.md](docs/USAGE.md) for the full command reference and guidance on granting an AI agent scoped vault access.

## Advanced details

### Debugging

`make test` runs the full BATS test suite and is the primary way to confirm correct behaviour.

Check the vault path structure directly if a credential is not found:

```shell
bao kv list oh/hubs/<hub>/
```

Verify a single credential against its exchange:

```shell
oh-cred verify hub-a myorg admin
```

If `verify-all` is returning unexpected failures, check whether the hub is reachable and whether the credential has been marked `suspect` (circuit-breaker state). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details on the back-off behaviour.

### All Makefile targets

* `default` - run `test`
* `test` - run the full BATS test suite (`bats test/*.bats`)
* `install` - install `bin/oh-cred` to `$(DESTDIR)$(PREFIX)/bin` (default: `/usr/local/bin`)
* `uninstall` - remove `oh-cred` from `$(DESTDIR)$(PREFIX)/bin`
* `lint` - run `shellcheck` over `bin/oh-cred` and all scripts in `scripts/`
* `clean` - remove generated artefacts (`tmp/`, `scratch/`, `coverage/`, `*.log`)
