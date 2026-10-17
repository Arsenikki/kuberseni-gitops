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

## Architecture & key decisions (why it's built this way)

Non-obvious choices — full rationale is in each manifest's comments:

- **`wrapped-chromium` override (`launch-fix.yaml`).** Selkies' desktop *autostart*
  applies `CHROME_CLI`, but any *relaunch* (crash, closing the window, the desktop
  menu) re-runs `wrapped-chromium` with **no args** — so the extensions **and** the
  CDP debug port silently vanish ("worked once, then broke"). We mount a hardened
  override of `/usr/bin/wrapped-chromium` (a ConfigMap, `subPath`) that hardcodes
  the profile + `--remote-debugging-port=9222` + both extensions, so every launch
  path is identical. Keep it in sync with the upstream wrapper if the image bumps.
- **CDP needs a non-default `--user-data-dir`.** Chrome 136+ ignores
  `--remote-debugging-port` on the *default* profile (security hardening), so the
  wrapper uses `--user-data-dir=/config/cdp-profile`.
- **Self-heal liveness probe (`deployment.yaml`) checks CDP (`:9222`), not the
  stream (`:3000`).** The Selkies stream server stays up even when the *browser*
  process dies, so a `:3000` probe never notices a dead browser. Liveness `exec`s a
  curl against CDP → dead browser ⇒ container restarts ⇒ autostart ⇒ override ⇒
  back with extensions + CDP.
- **Auth = Authentik only.** Registration is the `app-chrome` blueprint in
  `cluster/apps/authentik/resources/` (+ its binding in `embedded-outpost.yaml`).
  Any new app behind `authentik-forward-auth` ALSO needs a blueprint there or it
  404s with "Not Found".
- **Opener** (`opener.yaml`) = a token-gated sidecar that drives the running
  Chromium via localhost CDP (`/json/new`) and 302-redirects to the viewer.

## Performance & GPU — READ before trying to GPU-accelerate

**This runs on SOFTWARE video encoding (x264) + software rendering — there is no
GPU.** For a single-user reader that's fine: CPU is not the idle bottleneck
(measured ~0.03% throttling), and the "streamed, not local" feel is inherent
remote-desktop latency a GPU would not remove.

**⚠️ GPU acceleration was attempted (Oct 2026) and REVERTED — do not naively retry:**
- On worker-01's Intel Iris Xe iGPU, **VAAPI would not initialize**:
  `iHD_drv_video.so init failed` *even as root on the accessible render node*. Root
  cause: the image's bundled Intel userspace driver
  (`intel-media-va-driver-non-free` **25.2.3**, Debian trixie) is **too old for the
  Talos kernel (6.18)**. It is NOT a permissions / `card0` issue. (Plex works on
  the same GPU only because it bundles its *own* newer driver — each container ships
  its own userspace VAAPI driver; the kernel i915 side is shared and fine.)
- The `--ignore-gpu-blocklist` / `--enable-features=Vaapi*` Chromium flags then
  **forced Chromium onto the broken GPU → crashloop** (desktop kept dying → CDP
  never bound → the liveness probe restart-looped). Reverted in PR #733.

**The ONLY viable GPU path** (if ever worth it): a thin **custom image**
`FROM lscr.io/linuxserver/chromium` that installs a newer driver *trio* —
`intel-media-va-driver-non-free 26.2.4` + `libva2 ≥2.24` + `libigdgmm12` +
`mesa-va-drivers` from **Debian forky/sid** (NOT trixie-backports — the driver is
absent there; a newer lscr *tag* won't help — still trixie 25.2.3), APT-pinned so
only the Intel bits come from forky. Then: bump `GpuDevicePlugin.sharedDevNum`
1→2 (shares the iGPU with Plex, does not evict it), **prove VAAPI with a throwaway
`vainfo`/`ffmpeg` probe pod BEFORE touching prod**, and deploy with **only**
`DRINODE`/`DRI_NODE` + `gpu.intel.com/i915: 1` + `supplementalGroups: [44,110]` —
**NO forcing flags** (Selkies falls back to software gracefully, so it can't
crashloop). ~70% chance it works first-try. **Verdict: not worth the custom-image
maintenance for one user — stay on software unless you hit real CPU/stream pain.**

**Smoothness tuning (software encode)** — most are adjustable live in the Selkies
sidebar (no restart); bake chosen values into the Deployment `env` if you like:
- **CSS scaling** (`SELKIES_USE_CSS_SCALING=true`) or a lower resolution — fewer
  pixels to encode = smoother; the biggest lever.
- A steady **`SELKIES_FRAMERATE=30`** often feels smoother than a stuttery 60.
- Raise **`SELKIES_VIDEO_CRF`** (default 25 → ~28) if choppy during motion;
  paint-over re-sharpens static text.
- Bitrate isn't the constraint on a LAN. More CPU headroom (a bigger node) *may*
  help scroll smoothness, but **measure scroll-time CPU first** — it was never
  confirmed to saturate.
