# fleet-verifier — read-only across every hub, for `oh-cred verify-all`.
#
# Note the paths are anchored at hubs/ rather than being a bare oh/data/*.
# A wildcard at the root would silently pick up oh/seal/* and oh/wifi/*, handing
# the health check the fleet's unseal keys and root tokens. It does not need
# them and must not have them.
path "oh/data/hubs/*"     { capabilities = ["read"] }
path "oh/metadata/hubs/*" { capabilities = ["read", "list"] }
path "oh/metadata/hubs"   { capabilities = ["list"] }
