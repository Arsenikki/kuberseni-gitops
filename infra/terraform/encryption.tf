# OpenTofu native state & plan encryption (AES-256-GCM).
# State is encrypted at rest so terraform.tfstate can be committed to git.
#
# The PBKDF2 key_provider (which holds the passphrase) is NOT defined here — it
# is injected at runtime via the TF_ENCRYPTION environment variable, sourced
# from encryption.sops.yaml (age-encrypted, same key as the rest of the repo).
# See the terraform:* tasks in infra/Taskfile.yml. This keeps the secret out of
# any committed .tf file. Recovery needs only: this repo + the age key (backed
# up in 1Password).
#
# `enforced = true` makes OpenTofu refuse to read/write UNENCRYPTED state, so a
# run without TF_ENCRYPTION fails loudly instead of silently writing plaintext.
terraform {
  encryption {
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
