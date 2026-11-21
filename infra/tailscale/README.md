# infra/tailscale: the tailnet policy

`policy.hujson` is the tailnet's access policy (grants, tags, auto-approvers). `apply.sh` validates it, diffs it against the live policy, and applies it with `--apply`.

## Who gets what

| Who | Reaches |
|---|---|
| Admins (the owner) | Everything: every home zone, the router, the exit node |
| Every member | Their own devices; the home's user-facing services (k8s LoadBalancer IPs except MQTT); the router's DNS; the exit node |

This matches the TRUSTED Wi-Fi zone on the router (`infra/nixos/hosts/gw`). The router's firewall lets the tailnet in to every zone, so this file is the real control.

## One-time setup (owner)

1. **Create an OAuth client** in the admin console (Settings → OAuth clients). Give it the `policy_file` scope, plus `auth_keys` with tag `tag:router` for step 3. Store it in 1Password, homelab vault, as item `tailscale-oauth` with fields `client_id` and `client_secret`.
2. **Apply the policy.** Run `infra/tailscale/apply.sh` and review the diff, then run `infra/tailscale/apply.sh --apply`.
3. **After the router switchover, make gw a tagged node.** It currently runs as the old OPNSense node `opnsense`, which is owned by a user and has a key that expires.
   - On gw:
     ```sh
     tailscale up --force-reauth --advertise-tags=tag:router \
       --auth-key "$(op read op://homelab/tailscale-oauth/client_secret)?preauthorized=true&ephemeral=false"
     ```
   - Tagged nodes don't expire, and `autoApprovers` approves its routes and exit node.
   - Then remove the old `opnsense` node in the console.
