# Policies

These were previously described in prose in `INSTALL.md` but never committed, so
the actual scope of `fleet-verifier` was not reviewable. They are checked in here
because the security boundary between the trees is the whole point of the schema.

| Policy | Consumer | Reaches |
|---|---|---|
| `llm-hub-ro.hcl.tmpl` | per-hub agent AppRole | one hub's `meta` + `users` only |
| `fleet-verifier.hcl` | `check_all` health check | every hub's `meta` + `users`, nothing else |
| `oh-seal-operator.hcl` | `oh-cred unseal` | `oh/seal/*` only |
| `oh-wifi-ro.hcl` | `oh-cred wifi-run` | `oh/wifi/*` only |
| `human-admin.hcl` | a person, via userpass | all of `oh/*` |

**The boundary that matters:** seal material and wifi PSKs live *outside*
`oh/hubs/`, so the hub-scoped wildcards (`oh/data/hubs/<hub>/*`) cannot reach
them. That is a structural guarantee, not an explicit deny that can be dropped in
a later edit. Do not "simplify" any of these to `oh/data/*`.

Apply with:

```bash
bao policy write fleet-verifier   fleet-verifier.hcl
bao policy write oh-seal-operator oh-seal-operator.hcl
bao policy write oh-wifi-ro       oh-wifi-ro.hcl
bao policy write human-admin      human-admin.hcl
sed 's/<hub>/edge1/g' llm-hub-ro.hcl.tmpl | bao policy write llm-edge1-ro -
```
