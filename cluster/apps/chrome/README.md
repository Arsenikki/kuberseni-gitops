# chrome — remote Chromium + Bypass Paywalls Clean

A self-hosted [`linuxserver/chromium`](https://docs.linuxserver.io/images/docker-chromium/)
(Selkies) remote browser at **https://chrome.arsenikki.casa**, with the
[Bypass Paywalls Clean](https://gitflic.ru/project/magnolia1234/bypass-paywalls-chrome-clean)
(BPC) extension loaded so paywalled articles render. Open it in your normal
browser → you get a Chromium running in the cluster.

## ⚠️ Security model — read before trusting this

This pod is an **interactive, outbound-capable browser foothold** sitting on the
same cluster/LAN as Proxmox, TrueNAS, ArgoCD and Postgres. A full adversarial
threat model was done; two controls are **load-bearing** and the rest is
defense-in-depth:

1. **Internal-only.** `ingress.yaml` sets `external-dns/is-public: "false"` — no
   public DNS record. Reach it over the LAN / Tailscale. Authentik forward-auth
   is layered on top, not instead.
2. **Validated egress lockdown.** `networkpolicy.yaml` blocks the pod from
   reaching the LAN / cluster admin planes. **It MUST be validated on the live
   cluster** (see below) — a silent mis-match leaves the LAN reachable while the
   YAML still reads correct.

"I never log into sites" removes credential-theft risk but does **nothing** for
the LAN pivot, the extension supply chain, or open-relay abuse — hence the two
controls above. Trust the **image** (pinned by tag), not the **extension** (BPC
is unsigned JS from a Russian git host, so it's reviewed + pinned by hand and
loaded with `--disable-extensions-except` so only BPC can run).

## Auth

**Authentik forward-auth only.** The Selkies basic-auth (CUSTOM_USER/PASSWORD) is
intentionally NOT set — the backend is unreachable except via Traefik, which
enforces Authentik (Service is ClusterIP-only; the CiliumNetworkPolicy ingress
admits `:3000` from the Traefik pod only). Registration lives in the Authentik
`app-chrome` blueprint. Tradeoff: no fallback gate if forward-auth is bypassed;
accepted for a single-user, internal-only app.

## One-tap "Open unpaywalled" opener (iOS + Mac)

Instead of navigating here and pasting a URL, push the current page in one tap.
`opener.arsenikki.casa` (Tailscale-only, token-gated — a sidecar in this pod)
opens the URL in this browser via Chromium's localhost CDP, then 302-redirects you
to the viewer:

    https://opener.arsenikki.casa/open?token=<TOKEN>&url=<URL-ENCODED-ARTICLE>

Token = 1Password item `chrome-opener` (field `password`). The article URL **must
be URL-encoded** (it's a query param). Needs Tailscale up + internal DNS.

**iOS Shortcut "Open unpaywalled"** (Details → Show in Share Sheet → accept URLs):
1. *(Share Sheet input)* — Receive URLs
2. **URL Encode** → Shortcut Input
3. **Text**: `https://opener.arsenikki.casa/open?token=<TOKEN>&url=` + the *URL-Encoded* variable
4. **Open URLs** → that Text

**Mac bookmarklet** (Bookmark → Edit → paste into the *URL* field; don't paste in the address bar):

    javascript:location.href='https://opener.arsenikki.casa/open?token=<TOKEN>&url='+encodeURIComponent(location.href);

The token in the URL is the CSRF/abuse gate — keep the Shortcut/bookmarklet private.

## One-time: install BPC into the PVC

The PVC starts empty, so Chromium first boots with no extension. Populate it:

```bash
# 1. Download + unzip the reviewed BPC Chromium build locally
curl -fsSL -o bpc.zip \
  'https://gitflic.ru/project/magnolia1234/bpc_uploads/blob/raw?file=bypass-paywalls-chrome-clean-master.zip'
unzip bpc.zip                      # -> bypass-paywalls-chrome-clean-master/

# 2. (recommended) eyeball the manifest + host_permissions before loading
grep -R "host_permissions\|matches" bypass-paywalls-chrome-clean-master/manifest.json

# 3. Copy it into the running pod's /config/bpc, then restart to load it
POD=$(kubectl -n chrome get pod -l app=chrome -o jsonpath='{.items[0].metadata.name}')
kubectl -n chrome cp bypass-paywalls-chrome-clean-master "$POD:/config/bpc"
kubectl -n chrome rollout restart deploy/chrome
```

Verify at `chrome://extensions` inside the remote browser that BPC is enabled.

## One-time: install uBlock Origin Lite (ad-blocking) into the PVC

BPC strips the paywall but not ads, so we also load **uBlock Origin Lite** (uBOL)
— MV3, since Chromium 154 has removed MV2 so classic uBlock Origin can't run.
Official source: gorhill's `uBlockOrigin/uBOL-home` releases (the `.chromium.zip`).

```bash
# 1. Download the latest reviewed uBOL chromium build (MV3)
URL=$(gh api repos/uBlockOrigin/uBOL-home/releases/latest \
  --jq '.assets[] | select(.name|test("chromium\\.zip$")) | .browser_download_url')
curl -fsSL -o ubol.zip "$URL" && mkdir ubol && unzip -q ubol.zip -d ubol

# 2. Copy into /config/ubol, then restart to load it (loaded via CHROME_CLI)
POD=$(kubectl -n chrome get pod -l app=chrome -o jsonpath='{.items[0].metadata.name}')
kubectl -n chrome cp ubol "$POD:/config/ubol"
kubectl -n chrome rollout restart deploy/chrome
```

uBOL blocks most ads out of the box via network (DNR) filtering with no setup.
For best results (hiding leftover ad containers), open uBOL's popup in the remote
browser once and raise the filtering mode to **Optimal** or **Complete** (grants
broad site access for cosmetic filtering). Both extensions are allowlisted in the
Deployment's `CHROME_CLI` (`--disable-extensions-except=/config/bpc,/config/ubol`).

## Updating the extensions (manual, by choice)

Unpacked extensions don't auto-update. When a site stops being unpaywalled (BPC)
or ads creep back (uBOL), repeat the relevant one-time steps — re-download, **diff
against the current `/config/<ext>` before copying** (your supply-chain
checkpoint), copy, `rollout restart`. Pin to a reviewed release, not blind latest.

## ✅ Validate the egress lockdown (do not skip)

After first sync, confirm the pod genuinely cannot reach the LAN/cluster:

```bash
kubectl -n chrome exec deploy/chrome -- sh -c '
  curl -m5 -s -o /dev/null -w "LAN %{http_code}\n"  http://<router-or-truenas-LAN-IP>  || echo "LAN blocked (good)";
  curl -m5 -s -o /dev/null -w "NET %{http_code}\n"  https://example.com                || echo "NET broken (bad)";
  getent hosts example.com >/dev/null && echo "DNS ok" || echo "DNS broken (bad)";
'
# And watch drops live:
hubble observe -n chrome --pod chrome --verdict DROPPED -f
```

Expected: LAN/cluster/apiserver **blocked**, internet **works**, DNS **works**.
Re-run after any Cilium upgrade. See the CAVEATS block in `networkpolicy.yaml`.

## Residual risks / follow-ups (from the security review)

- **Traefik version:** confirm the running Traefik app is ≥ v3.7.13 (chart 41.x)
  for the ForwardAuth bypass fixes. (Cilium 1.19.4 ✓ and Authentik 2026.5.4 ✓
  are already past their relevant CVEs.)
- **Container hardening gaps:** linuxserver/s6 images start as root and can't run
  `runAsNonRoot` / drop-all-caps / readOnlyRootFilesystem without breaking; the
  network isolation + `automountServiceAccountToken: false` + baseline PSA +
  `HARDEN_DESKTOP`/`DISABLE_SUDO`/`DISABLE_TERMINALS` compensate. Consider a
  gVisor/Kata RuntimeClass later for true escape isolation.
- **Chromium currency:** keep the image tag bumped — a renderer 0-day on a hostile
  page meets a seccomp-Unconfined pod, so patch cadence matters.
- **Second egress gate (optional):** a gluetun/WireGuard sidecar or Cilium Egress
  Gateway would survive a NetworkPolicy mistake. Not included here.
