#!/usr/bin/env bash
# Bootstrap the Talos cluster with ArgoCD, ESO, and 1Password Connect.
# Run from the repo root: bash infra/scripts/bootstrap-cluster.sh
#
# Prerequisites:
#   - kubectl context admin@kuberseni is set and cluster is reachable
#   - op CLI signed in to my.1password.eu (eval $(op signin --account my.1password.eu))
#   - 1password-credentials.json downloaded from 1password.com → Integrations → Connect

set -euo pipefail

CONTEXT="admin@kuberseni"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CREDENTIALS_FILE="${1:-$REPO_ROOT/1password-credentials.json}"

kube() { kubectl --context "$CONTEXT" "$@"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
echo "→ Checking prerequisites..."
kubectl --context "$CONTEXT" get nodes --no-headers | awk '{print "  node:", $1, $2}'

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  echo ""
  echo "ERROR: 1password-credentials.json not found at: $CREDENTIALS_FILE"
  echo "Download it from: 1password.com → Integrations → 1Password Connect → your server"
  echo "Then re-run: bash infra/scripts/bootstrap-cluster.sh /path/to/1password-credentials.json"
  exit 1
fi

echo "  credentials file: $CREDENTIALS_FILE ✓"
echo ""

# ── Helm repos ────────────────────────────────────────────────────────────────
echo "→ Adding Helm repos..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo add 1password https://1password.github.io/connect-helm-charts 2>/dev/null || true
helm repo update > /dev/null
echo "  done"

# ── ArgoCD ────────────────────────────────────────────────────────────────────
echo ""
echo "→ Installing ArgoCD..."
helm upgrade --install argocd argo/argo-cd \
  --kube-context "$CONTEXT" \
  --namespace argocd --create-namespace \
  --wait \
  -f "$REPO_ROOT/cluster/bootstrap/argocd/values.yaml"
echo "  ArgoCD installed ✓"

# ── ESO ───────────────────────────────────────────────────────────────────────
echo ""
echo "→ Installing External Secrets Operator..."
helm upgrade --install external-secrets external-secrets/external-secrets \
  --kube-context "$CONTEXT" \
  --namespace external-secrets --create-namespace \
  --wait \
  -f "$REPO_ROOT/cluster/bootstrap/eso/values.yaml"
echo "  ESO installed ✓"

# ── 1Password Connect ─────────────────────────────────────────────────────────
echo ""
echo "→ Installing 1Password Connect..."
helm upgrade --install onepassword-connect 1password/connect \
  --kube-context "$CONTEXT" \
  --namespace external-secrets \
  --wait \
  --set connect.credentials_base64="$(base64 -i "$CREDENTIALS_FILE")"
echo "  1Password Connect installed ✓"

# ── Connect token secret ──────────────────────────────────────────────────────
echo ""
echo "→ Creating 1Password Connect token secret..."
echo "  Fetching token from 1Password..."
# Fetch the Connect token we stored during vault setup — or prompt
CONNECT_TOKEN=$(op read "op://homelab/1password-connect-token/token" --account my.1password.eu 2>/dev/null || true)

if [[ -z "$CONNECT_TOKEN" ]]; then
  echo ""
  read -rsp "  Paste your 1Password Connect access token: " CONNECT_TOKEN
  echo ""
fi

kube create secret generic onepassword-connect-token \
  --namespace external-secrets \
  --from-literal=token="$CONNECT_TOKEN" \
  --dry-run=client -o yaml | kube apply -f -
echo "  Token secret created ✓"

# ── ClusterSecretStore ────────────────────────────────────────────────────────
echo ""
echo "→ Applying ClusterSecretStore..."
kube apply -f "$REPO_ROOT/cluster/bootstrap/eso/secretstore.yaml"
echo "  ClusterSecretStore applied ✓"

# ── Root Application ──────────────────────────────────────────────────────────
echo ""
echo "→ Applying ArgoCD root Application..."
kube apply -f "$REPO_ROOT/cluster/argocd/root-app.yaml"
echo "  Root app applied ✓"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "Bootstrap complete! ArgoCD is now syncing the cluster."
echo ""
echo "Get the ArgoCD admin password:"
echo "  kubectl --context $CONTEXT get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "ArgoCD UI will be available at: https://argocd.arsenikki.casa (once Traefik is up)"
echo "Or port-forward: kubectl --context $CONTEXT port-forward svc/argocd-server -n argocd 8080:443"
