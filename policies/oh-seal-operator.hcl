# oh-seal-operator — used by `oh-cred unseal` / `seal-status`.
#
# This is the most sensitive role in the estate: oh/seal/<hub> holds a hub's
# unseal key shares AND its bao root token. Grant it to the unseal watchdog and
# to operators, never to a general-purpose agent role.
#
# Read-only: rotating or re-keying seal material is a human, audited act.
path "oh/data/seal/*"     { capabilities = ["read"] }
path "oh/metadata/seal/*" { capabilities = ["read", "list"] }
path "oh/metadata/seal"   { capabilities = ["list"] }
