# oh-wifi-ro — used by `oh-cred wifi-run`.
# Read-only access to wifi PSKs. Separate from seal material so that a host or
# image-build process can be given network credentials without ever being in
# reach of a vault root token.
path "oh/data/wifi/*"     { capabilities = ["read"] }
path "oh/metadata/wifi/*" { capabilities = ["read", "list"] }
path "oh/metadata/wifi"   { capabilities = ["list"] }
