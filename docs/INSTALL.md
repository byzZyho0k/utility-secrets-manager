# Install

Standing up `oh-cred` from nothing.

Commands below use OpenBao (`bao`). HashiCorp Vault (`vault`) is API-compatible
for everything used here; substitute the binary name.

---

## Platform-specific prerequisites

Jump to the section for your platform, then continue from step 2 onward.

- [macOS (Apple Silicon / arm64)](#macos-apple-silicon--arm64)
- [macOS (Intel / x86\_64)](#macos-intel--x8664)
- [Linux (Debian/Ubuntu)](#linux-debianubuntu)

---

## macOS (Apple Silicon / arm64)

Homebrew installs to `/opt/homebrew`. Everything that follows uses that prefix.

### Install dependencies

```bash
brew install openbao jq curl
```

`hzn` (Open Horizon CLI) must also be present for commands run via `oh-cred run`.
Install it separately if needed.

### Directory layout

The Homebrew package does not create config, data, log, or TLS directories — do
that now:

```bash
mkdir -p /opt/homebrew/etc/openbao/tls
mkdir -p /opt/homebrew/etc/openbao/approle
mkdir -p /opt/homebrew/var/log/openbao
mkdir -p /opt/homebrew/var/openbao/data
chmod 700 /opt/homebrew/etc/openbao/approle
```

### TLS certificate

The Homebrew plist defaults to `-dev` mode (no TLS, in-memory storage). We
replace it with a proper server config. First, generate a certificate with SANs
so TLS verification actually works:

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -days 1095 -nodes \
  -keyout /opt/homebrew/etc/openbao/tls/tls.key \
  -out    /opt/homebrew/etc/openbao/tls/tls.crt \
  -subj "/O=OpenBao/CN=openbao.localhost" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost,DNS:openbao.localhost"

chmod 600 /opt/homebrew/etc/openbao/tls/tls.key
chmod 644 /opt/homebrew/etc/openbao/tls/tls.crt
```

> On macOS the packaged `openssl` may be LibreSSL, which does not support
> `-addext`. Install OpenSSL 3 via Homebrew (`brew install openssl@3`) and use
> `/opt/homebrew/opt/openssl@3/bin/openssl` if the command above fails.

### vault config — `/opt/homebrew/etc/openbao/openbao.hcl`

```hcl
storage "file" {
  path = "/opt/homebrew/var/openbao/data"
}

listener "tcp" {
  address       = "127.0.0.1:8200"
  tls_cert_file = "/opt/homebrew/etc/openbao/tls/tls.crt"
  tls_key_file  = "/opt/homebrew/etc/openbao/tls/tls.key"
}

audit "file" "fleet-audit" {
  description = "Audit log for credential access."
  options {
    file_path = "/opt/homebrew/var/log/openbao/audit.log"
  }
}
```

> The `audit` stanza takes **two labels** (type and name) with settings in a
> nested `options` block. A single label or `file_path` at the top level fails
> to parse.

### LaunchAgent — start on login

Homebrew's default plist runs `-dev` mode. Replace it with one that uses the
config file. Write to `~/Library/LaunchAgents/homebrew.mxcl.openbao.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>        <string>homebrew.mxcl.openbao</string>
  <key>KeepAlive</key>    <true/>
  <key>RunAtLoad</key>    <true/>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/opt/openbao/bin/bao</string>
    <string>server</string>
    <string>-config=/opt/homebrew/etc/openbao/openbao.hcl</string>
  </array>
  <key>StandardOutPath</key>
    <string>/opt/homebrew/var/log/openbao/openbao.log</string>
  <key>StandardErrorPath</key>
    <string>/opt/homebrew/var/log/openbao/openbao.log</string>
  <key>WorkingDirectory</key>
    <string>/opt/homebrew/var/openbao</string>
  <key>LimitLoadToSessionType</key>
  <array>
    <string>Aqua</string>
    <string>Background</string>
    <string>LoginWindow</string>
    <string>StandardIO</string>
    <string>System</string>
  </array>
</dict>
</plist>
```

Load (or reload) it:

```bash
launchctl unload ~/Library/LaunchAgents/homebrew.mxcl.openbao.plist 2>/dev/null || true
launchctl load  ~/Library/LaunchAgents/homebrew.mxcl.openbao.plist
```

Set the environment variables used by every `bao` and `oh-cred` command.
Add them to `~/.zshrc` (or `~/.bash_profile`):

```bash
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT=/opt/homebrew/etc/openbao/tls/tls.crt
export OH_CRED_APPROLE_DIR=/opt/homebrew/etc/openbao/approle
```

`OH_CRED_APPROLE_DIR` tells `oh-cred` where to find AppRole credential files.
The default (`/etc/openbao/approle`) is the Linux path; macOS needs this override.

Then source the file and continue from [step 4](#4-initialise-and-unseal).

### Auto-unseal on macOS

On macOS, systemd is not available. The unseal step is a separate LaunchAgent
that runs *after* the vault agent has started.

Write `/opt/homebrew/etc/openbao/bao-autounseal.sh`:

```bash
#!/usr/bin/env bash
# Persistent daemon — polls every 5s and unseals whenever the vault is
# sealed-but-running (exit 2 from bao status). Handles vault restarts
# automatically without needing to be reloaded.
KEYS=/opt/homebrew/etc/openbao/unseal.keys
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT=/opt/homebrew/etc/openbao/tls/tls.crt
BAO=/opt/homebrew/bin/bao

while true; do
  # bao status exits: 0 = unsealed, 2 = sealed-but-running, other = not up yet
  "$BAO" status -format=json >/dev/null 2>&1
  if [ $? -eq 2 ]; then
    while IFS= read -r key; do
      "$BAO" operator unseal "$key" >/dev/null 2>&1
    done < "$KEYS"
  fi
  sleep 5
done
```

```bash
chmod 700 /opt/homebrew/etc/openbao/bao-autounseal.sh
```

Write `~/Library/LaunchAgents/local.openbao-autounseal.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>         <string>local.openbao-autounseal</string>
  <key>KeepAlive</key>     <true/>
  <key>RunAtLoad</key>     <true/>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/etc/openbao/bao-autounseal.sh</string>
  </array>
  <key>StandardOutPath</key>
    <string>/opt/homebrew/var/log/openbao/autounseal.log</string>
  <key>StandardErrorPath</key>
    <string>/opt/homebrew/var/log/openbao/autounseal.log</string>
</dict>
</plist>
```

`KeepAlive=true` keeps the daemon resident — launchd restarts it if it ever
exits, so it survives vault process restarts without any manual step.

Load it **after** completing steps 4 and 9 below:

```bash
launchctl load ~/Library/LaunchAgents/local.openbao-autounseal.plist
```

**Test it**: restart the vault agent (`launchctl unload` then `launchctl load`
on `homebrew.mxcl.openbao`), then confirm `bao status` shows `Sealed: false`
within ~10 seconds and `oh-cred list` works without any manual step.

---

## macOS (Intel / x86\_64)

The steps are identical to the arm64 section above with two differences:

1. Homebrew installs to `/usr/local` instead of `/opt/homebrew`. Substitute
   `/usr/local` everywhere `/opt/homebrew` appears.
2. The LaunchAgent `ProgramArguments` path becomes
   `/usr/local/opt/openbao/bin/bao`.

All other commands, config files, and file paths are the same.

---

## Linux (Debian/Ubuntu)

Requires `jq`, `curl`, and `openssl` (`apt install jq curl openssl`).

### Install the vault

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

---

## 2. Fix the listener and the certificate

> **macOS users:** this step is already covered by the TLS section above. Skip
> to [step 3](#3-configure-the-audit-device).

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

> **macOS users:** the audit stanza is already part of the HCL shown above.
> Ensure the log directory exists (`mkdir -p
> /opt/homebrew/var/log/openbao`), then skip to
> [step 4](#4-initialise-and-unseal).

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

**Linux:**

```bash
export BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/opt/openbao/tls/tls.crt
```

**macOS arm64:**

```bash
export BAO_ADDR=https://127.0.0.1:8200
export BAO_CACERT=/opt/homebrew/etc/openbao/tls/tls.crt
```

Then initialise:

```bash
umask 077; bao operator init -key-shares=5 -key-threshold=3 \
  -format=json > ~/bao-init.json
```

> **Linux:** run under `sudo bash -c '...'` and write to `/root/bao-init.json`
> to keep the output root-owned.

**Never let this output reach a terminal, a transcript, or a repository.** Write
it straight to a root-only file, then move the shares and root token to a
password manager or offline storage and shred the file.

Unseal with three shares:

```bash
for i in 0 1 2; do
  bao operator unseal "$(jq -r ".unseal_keys_b64[$i]" ~/bao-init.json)" >/dev/null
done
```

Export the root token from the init output so subsequent setup commands work:

```bash
export BAO_TOKEN=$(jq -r '.root_token' ~/bao-init.json)
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
# Linux
sudo install -d -m 750 -o root -g <your-group> /etc/openbao/approle
# macOS
mkdir -p /opt/homebrew/etc/openbao/approle
chmod 700 /opt/homebrew/etc/openbao/approle
# write ROLE_ID= / SECRET_ID= to approle/<role>.env, mode 0600
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

## 9. Auto-unseal

Only if you accept the tradeoff in ARCHITECTURE.md: shares on the vault host mean
root there reaches every credential. Appropriate for a single-operator machine
with restricted physical access; **not** for a shared or remote host.

**Linux:**

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

**macOS:** see the auto-unseal subsection in the macOS platform section above.

**Test it with a real restart and a cold start**, then confirm `oh-cred` works
with no manual step.

## 10. Import existing credentials

Follow the gated workflow in ARCHITECTURE.md — inventory, fingerprint, import,
`verify-all`, and only then shred the plaintext. Do not skip the fingerprint
step; it is what catches files that look like duplicates but are not.
