#!/usr/bin/env bash
# Validate the tailnet policy, show what changes, and apply it.
#
#   infra/tailscale/apply.sh          # validate + diff only
#   infra/tailscale/apply.sh --apply  # ...then apply
#
# Credentials: a Tailscale OAuth client with the `policy_file` scope, in 1Password
# item `tailscale-oauth` (homelab vault; fields `client_id`, `client_secret`). Create it
# once in the admin console: Settings > OAuth clients.
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
policy=$here/policy.hujson
api=https://api.tailscale.com/api/v2

: "${TS_CLIENT_ID:=$(op read 'op://homelab/tailscale-oauth/client_id')}"
: "${TS_CLIENT_SECRET:=$(op read 'op://homelab/tailscale-oauth/client_secret')}"
token=$(curl -fsS -d "client_id=$TS_CLIENT_ID" -d "client_secret=$TS_CLIENT_SECRET" "$api/oauth/token" | jq -r .access_token)
auth=(-H "Authorization: Bearer $token")

echo "validating $policy"
result=$(curl -fsS "${auth[@]}" -H 'Content-Type: application/hujson' --data-binary "@$policy" "$api/tailnet/-/acl/validate")
if [ -n "$(jq -r '.message // empty' <<<"$result")" ]; then
  jq . <<<"$result" >&2
  exit 1
fi

current=$(mktemp)
trap 'rm -f "$current"' EXIT
etag=$(curl -fsS "${auth[@]}" -H 'Accept: application/hujson' -D - -o "$current" "$api/tailnet/-/acl" |
  sed -n 's/^[Ee][Tt]ag: *//p' | tr -d '\r')
diff -u --label live "$current" --label repo "$policy" || true

if [ "${1:-}" = --apply ]; then
  curl -fsS "${auth[@]}" -H 'Content-Type: application/hujson' -H "If-Match: $etag" \
    --data-binary "@$policy" "$api/tailnet/-/acl" >/dev/null
  echo "applied"
fi
