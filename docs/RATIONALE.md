# Rationale — the ills this prevents

Every section below is a failure that actually occurred on a small Open Horizon
fleet: two self-hosted management hubs on separate subnets, plus two external
exchanges, about a dozen edge nodes, and an AI coding agent doing routine
operations. The tool exists because these are not hypothetical.

---

## 1. A credential that doesn't know which system it belongs to

**The failure.** Six credential files sat in a directory, named by org and user:
`root-root.env`, `myorg-admin.env`, `acme-admin.env`, and so on. Copies of the
same six files also sat on a second host. Nothing in any file recorded *which
exchange* the credential authenticated against.

The second host ran a **different** management hub, on a different subnet, that
happened to use the same org names. Every one of those credentials returned `401`
there. That is indistinguishable from an expired password.

The conclusion drawn was "these are dead" and they were deleted. They were not
dead — they were valid credentials for the other hub, and they still authenticate
today. Only the presence of copies elsewhere prevented real loss.

**Why it is a design problem, not a discipline problem.** "Remember to check
which hub" is exactly the kind of rule that holds until the day it matters. The
information was simply absent from the artifact.

**The fix.** Paths are keyed by hub *before* org and user:

```
oh/hubs/<hub>/users/<org>/<user>
```

You cannot fetch a credential without naming its hub, and the hub's endpoints
travel with it as metadata. "Which exchange does this answer to" is now a lookup,
not a judgement call.

---

## 2. Silent rotation

**The failure.** An org admin password was changed directly on one exchange. The
credential files on disk were never updated. Nothing detected the drift.

Three months later a routine operation returned `401`. Because the same host also
had a stale *endpoint* configured, the error was first attributed to the wrong
cause entirely, and the real problem — a password nobody had propagated — took
considerable digging to find.

**The fix.** Because each credential records the exchange it belongs to, it can
be tested automatically:

```bash
oh-cred verify-all
```

This authenticates every stored credential against its own recorded endpoint.
Wired into the fleet health check, a rotated password becomes a **monitored
condition on the next run** instead of a surprise months later. A `401` is
reported distinctly from a `403` — the latter means the password is good but the
account lacks rights, which is not a credential fault.

---

## 3. Secrets leaking into transcripts

**The failure.** While auditing credential files, a command printed them with the
values masked by a regex. The regex was anchored at the start of the line. One
file's lines were indented. The pattern didn't match, no substitution happened,
and a live credential was printed verbatim into an AI agent's conversation
history — a log that persists, gets summarised, and may be reviewed later.

**Why redaction is the wrong control.** Masking is applied *after* deciding to
handle the value, by a human or model writing a pattern under time pressure. It
fails open: a missed match prints the secret. It has to be right every time, in
every ad-hoc command, forever.

**The fix.** Injection instead of redaction. `oh-cred run` places the secret in a
child process's environment and nowhere else:

- not on stdout, so it cannot reach scrollback or a transcript
- not in a file
- not in `argv`, so it does not appear in `ps` to other users on the box

And critically: **there is no subcommand that prints a secret.** That is not an
oversight to be fixed by a `--show` flag. A tool that can print a secret will
eventually be asked to, by someone who is debugging and in a hurry. If a human
truly needs to read a value, they authenticate to the vault themselves under an
admin policy — a deliberate, audited, separate act.

---

## 4. Improvised retrieval

**The failure.** An agent needed an exchange credential. There was no documented
way to obtain one. So it searched: `~/*.env`, then `/etc/environment`, then
`~/.bashrc`, then `docker inspect` on the exchange container to pull the root
password out of the container's environment.

Every one of those steps is reasonable in isolation, and the last two were
correctly blocked by a permission gate. But the search itself is the hazard —
each attempt risks printing what it finds, and the blocked attempts produced
friction and dead ends rather than a working outcome.

**The fix.** One documented command, and explicit instructions in the agent's
project context to use it and to **stop rather than improvise**:

> If `oh-cred` cannot supply what you need, say so and stop. Do not go hunting in
> `*.env` files, `/etc/environment`, `docker inspect`, or shell configs.

An agent with a sanctioned path follows it. An agent without one invents one, and
its invention is optimised for finding the secret, not for protecting it.

---

## 5. "Looks like a duplicate" is not evidence

**The failure.** During cleanup, two files were queued for deletion as obvious
redundant copies:

- A file with the same name as one already imported. It turned out to hold a
  **different credential entirely**, for a **different (external) hub**, and it
  authenticated successfully. It was the only copy.
- A file that looked like another hub-credentials file. It held **23 keys** of
  hub provisioning material — exchange root and database passwords, agbot
  credentials, FDO service credentials, and that host's own vault unseal key and
  root token. None of it existed anywhere else.

Both were caught only because a verification gate ran before the deletion.

**The fix.** A deletion workflow with a mandatory gate:

1. Inventory every candidate file.
2. Fingerprint values (hash them — never print) to detect true duplicates.
3. Import anything not already stored.
4. Run `verify-all` and require it to pass.
5. Only then shred the plaintext.

Fingerprinting alone collapsed two identically-named files into one secret, and
proved a third was unique. Hashing lets you compare secrets without ever
displaying them.

---

## 6. Secrets stored where anyone can read them

**The failures**, all found in one directory tree:

- An admin password in `/etc/environment` — mode `644`, and applied to *every*
  user's session on the host.
- A hub's full provisioning secrets in a home directory.
- An install-summary file containing fifteen credentials at mode `755` —
  world-readable and executable.
- A vault's unseal key **and root token** in plaintext, in the same directory as
  the secrets that vault protects.
- All of the above inside a 2.6 GB directory with no `.gitignore`, one
  `git init` away from being committed alongside a personal access token.

**The fix.** Secrets live in the vault; the vault is reachable on loopback only,
over TLS, with per-role policies and an audit log. What remains on disk is
deliberately minimal and root-owned:

| Still on disk | Why | Protection |
|---|---|---|
| AppRole `role_id`/`secret_id` | bootstrap — something must authenticate | `0640 root:<group>`, grants only that role's scope |
| Unseal shares (if auto-unseal) | survive reboot unattended | `0600 root`; see the tradeoff in ARCHITECTURE.md |

Non-secret configuration — exchange URLs, org IDs, device IDs — deliberately
*stays* in world-readable files. Splitting config from secrets means the
convenient, globally-set file no longer needs to be a liability.

---

## 7. No accountability for automated access

**The failure.** Once you hand credentials to automated tools, "which tool read
the production admin credential, and when" becomes a question you cannot answer
if everything shares one secret and nothing is logged.

**The fix.** One AppRole per designated consumer, each scoped by policy to
specific hubs, each with short-lived tokens, all reads recorded by the vault's
audit device. Granting and revoking access to a specific tool is a one-line
operation, and the audit log attributes every read to a named role.

The audit device hashes secret values, so the log is safe to keep and ship. It is
also **fail-closed**: if the audit log cannot be written, the vault stops serving
requests. That is the correct default — unlogged access to credentials is worse
than no access — but it makes disk space on the vault host an availability
concern worth monitoring.

---

## The through-line

Six of these seven failures were not caused by anyone being careless. They were
caused by **information missing from the artifact** (which hub?), **controls that
fail open** (redaction), or **absent sanctioned paths** (so tools improvise).

The design response in each case is structural rather than procedural: make the
wrong thing impossible to express, make the right thing the easiest path, and
make drift a monitored condition rather than something you discover by accident.
