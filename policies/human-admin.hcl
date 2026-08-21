# human-admin — a person logged in via userpass. Full control of the tree,
# including the writes that oh-cred deliberately cannot perform.
path "oh/*"          { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/mounts/oh" { capabilities = ["read"] }
