# Install

Standing up `oh-cred` from nothing. Assumes a Linux host with `jq` and `curl`.

Commands below use OpenBao (`bao`). HashiCorp Vault (`vault`) is API-compatible
for everything used here; substitute the binary name.

---

## 1. Install the vault

Download the package for your platform and **verify its checksum against the
published `checksums.txt`** before installing — this binary is about to hold every
credential you own.

```bash
curl -sSLo openbao.deb https://github.com/openbao/openbao/releases/download/vX.Y.Z/openbao_X.Y.Z_linux_amd64.deb
curl -sSLo checksums.txt https://github.com/openbao/openbao/releases/download/vX.Y.Z/checksums.txt
grep "openbao_X.Y.Z_linux_amd64.deb$" checksums.txt | awk '{print $1}'
sha256sum openbao.deb | awk '{print $1}'    # must match

sudo dpkg -i openbao.deb
```

## 2. Fix the listener and the certificate

Packaged installs commonly ship two defaults you do not want: a listener on
`0.0.0.0`, and a self-signed certificate **with no SANs** (which modern TLS
rejects, pushing you toward `-tls-skip-verify`).

Generate a certificate that actually verifies:

```bash
sudo openssl req -x509 -newkey rsa:4096 -sha256 -days 1095 -nodes \
  -keyout /opt/openbao/tls/tls.key -out /opt/openbao/tls/tls.crt \
  -subj "/O=OpenBao/CN=openbao.localhost" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:openbao.localhost"

sudo chown openbao:openbao /opt/openbao/tls/tls.{key,crt}
sudo chmod 600 /opt/openbao/tls/tls.key
sudo chmod 644 /opt/openbao/tls/tls.crt   # public cert — clients must read it
sudo chmod 755 /opt/openbao/tls           # …and traverse the directory
```

Then bind to loopback in `/etc/openbao/openbao.hcl`:

```hcl
listener "tcp" {
  address       = "127.0.0.1:8200"
  tls_cert_file = "/opt/openbao/tls/tls.crt"
  tls_key_file  = "/opt/openbao/tls/tls.key"
}
```

## 3. Configure the audit device

**Do this before storing any secret**, so the first writes are logged.

Recent OpenBao versions manage audit devices **declaratively** — the API path is
disabled and returns `cannot enable audit device via API`. Add to the config:

```hcl
audit "file" "fleet-audit" {
  description = "Audit log for credential access."
  options {
    file_path = "/var/log/openbao/audit.log"
  }
}
```

The stanza takes **two labels** — type and name — with settings in a nested
`options` block. A single label, or `file_path` at the top level, fails to parse.

```bash
sudo install -d -m 750 -o openbao -g openbao /var/log/openbao
sudo systemctl enable --now openbao
```

> Auditing is **fail-closed**: if that file cannot be written, the vault stops
> serving requests. Keep the volume monitored.

## 4. Initialise and unseal

```bash
export BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/opt/openbao/tls/tls.crt

sudo bash -c 'umask 077; bao operator init -key-shares=5 -key-threshold=3 \
  -format=json > /root/bao-init.json'
```

**Never let this output reach a terminal, a transcript, or a repository.** Write
it straight to a root-only file, then move the shares and root token to a
password manager or offline storage and shred the file.

Unseal with three shares:

```bash
sudo bash -c 'for i in 0 1 2; do
  bao operator unseal "$(jq -r ".unseal_keys_b64[$i]" /root/bao-init.json)" >/dev/null
done'
```

## 5. Enable the secrets engine

```bash
bao secrets enable -path=oh -version=2 kv
```

Version 2 is required — the schema depends on custom metadata and versioning.

## 6. Policies and roles

One read-only policy per hub. KV v2 needs both `data/` and `metadata/` paths:

```hcl
# llm-<hub>-ro.hcl
path "oh/data/hubs/<hub>/*"     { capabilities = ["read"] }
path "oh/metadata/hubs/<hub>/*" { capabilities = ["read","list"] }
path "oh/metadata/hubs/<hub>"   { capabilities = ["list"] }
```

Plus `fleet-verifier` (read-only across all hubs, for the health check) and
`human-admin` (full control of `oh/*`).

```bash
bao policy write llm-<hub>-ro   llm-<hub>-ro.hcl
bao policy write fleet-verifier fleet-verifier.hcl
bao policy write human-admin    human-admin.hcl

bao auth enable approle
bao auth enable userpass

bao write auth/approle/role/llm-<hub>-ro \
  token_policies="llm-<hub>-ro" token_ttl=1h token_max_ttl=4h \
  secret_id_ttl=0 token_num_uses=0
```

Store each role's credentials where the tool can read them and others cannot:

```bash
sudo install -d -m 750 -o root -g <your-group> /etc/openbao/approle
# write ROLE_ID= / SECRET_ID= to /etc/openbao/approle/<role>.env, mode 0640 root:<group>
```

**Verify the scoping actually holds** before trusting it:

```bash
# a hub-A token must be able to read hub A…
# …and must be DENIED hub B. If it is not, the policy is wrong.
```

## 7. Create a human login, then revoke root

```bash
bao write auth/userpass/users/<you> password="<generated>" \
  token_policies="human-admin" token_ttl=8h token_max_ttl=24h
```

Confirm it can read *and* write `oh/`, then retire the root token:

```bash
bao token revoke -self     # with BAO_TOKEN set to the root token
```

Recover later with `bao operator generate-root` and three unseal shares if ever
needed. Delete any bootstrap helper script that embedded the root token.

## 8. Install the client

```bash
sudo install -m 755 bin/oh-cred /usr/local/bin/oh-cred
oh-cred list
```

## 9. Optional — auto-unseal

Only if you accept the tradeoff in ARCHITECTURE.md: shares on the vault host mean
root there reaches every credential. Appropriate for a single-operator machine
with restricted physical access; **not** for a shared or remote host.

```bash
sudo bash -c 'umask 077; jq -r ".unseal_keys_b64[0:3][]" /root/bao-init.json \
  > /etc/openbao/unseal.keys'
```

A `oneshot` unit that applies those shares, wired so starting the vault pulls it
in:

```ini
[Unit]
After=openbao.service
Requires=openbao.service
PartOf=openbao.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/bao-autounseal

[Install]
WantedBy=openbao.service multi-user.target
```

`PartOf` alone only propagates *stop* and *restart* — it will not start the unit.
`WantedBy=openbao.service` is what makes starting the vault trigger the unseal.

The unseal script should poll until the API answers: `bao status` exits `0` when
unsealed and `2` when up-but-sealed — both mean it is listening.

**Test it with a real restart and a cold start**, then confirm `oh-cred` works
with no manual step.

## 10. Import existing credentials

Follow the gated workflow in ARCHITECTURE.md — inventory, fingerprint, import,
`verify-all`, and only then shred the plaintext. Do not skip the fingerprint
step; it is what catches files that look like duplicates but are not.
