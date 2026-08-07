// Generate self-truthing KB pages from the kuberseni-gitops manifests.
// Runs in `prebuild` (after sync, locally + in Docker + in CI) so the "Reference"
// pages always reflect the deployed source and can never drift. Output goes into
// the Astro content dir (src/content/docs/generated) — transient and git-ignored,
// so docs/homelab/ stays purely hand-authored and nothing generated is committed.
//
// Scope is this repo's own manifests only (no cross-repo/private access):
//   - cluster/argocd/apps/*.yaml   -> the ArgoCD Application inventory + app-of-apps map
//   - cluster/apps/**              -> Ingress / IngressRoute hosts + a hostname sweep
import {
  readFileSync,
  readdirSync,
  writeFileSync,
  mkdirSync,
  rmSync,
  existsSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve, join } from "node:path";
import YAML from "yaml";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(scriptDir, "../../.."); // docs/site/scripts -> repo root
const clusterDir = join(repoRoot, "cluster");
const outDir = resolve(scriptDir, "../src/content/docs/generated");

// A Starlight "note" aside (renders as a styled callout). Must be Markdown, not a
// JSX `{/* */}` comment — these files are .md, where JSX comments print literally.
const BANNER =
  ":::note[Auto-generated]\n" +
  "Rendered from the `cluster/` manifests by `docs/site/scripts/generate.mjs` on every build — edit the manifests, not this page.\n" +
  ":::";

// Rebuild the generated tree from scratch every run.
rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

function walk(dir) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.isFile() && /\.ya?ml$/.test(e.name)) out.push(p);
  }
  return out;
}

function parseDocs(file) {
  try {
    return YAML.parseAllDocuments(readFileSync(file, "utf8"))
      .map((d) => {
        try {
          return d.toJSON();
        } catch {
          return null;
        }
      })
      .filter((o) => o && typeof o === "object");
  } catch {
    return [];
  }
}

const id = (s) => "n_" + String(s).replace(/[^a-zA-Z0-9]/g, "_");
const esc = (s) => String(s ?? "").replace(/\|/g, "\\|");

// ---------------------------------------------------------------- Applications
const apps = [];
for (const f of walk(join(clusterDir, "argocd", "apps"))) {
  for (const doc of parseDocs(f)) {
    if (doc.kind !== "Application") continue;
    const md = doc.metadata || {};
    const spec = doc.spec || {};
    const srcs = spec.sources || (spec.source ? [spec.source] : []);
    const parts = [];
    for (const s of srcs) {
      if (s.chart) parts.push(`${s.chart}@${s.targetRevision || "?"}`);
      else if (s.path) parts.push(s.path);
    }
    apps.push({
      name: md.name || "?",
      namespace: (spec.destination || {}).namespace || "",
      wave: String((md.annotations || {})["argocd.argoproj.io/sync-wave"] ?? ""),
      source: parts.join(", "),
      helm: srcs.some((s) => s.chart),
    });
  }
}
apps.sort(
  (a, b) =>
    a.wave.localeCompare(b.wave, undefined, { numeric: true }) ||
    a.name.localeCompare(b.name),
);

// app-of-apps map, grouped by sync-wave
const byWave = new Map();
for (const a of apps) {
  const w = a.wave === "" ? "unset" : a.wave;
  if (!byWave.has(w)) byWave.set(w, []);
  byWave.get(w).push(a);
}
let appMermaid = "```mermaid\nflowchart LR\n  root([root app-of-apps])\n";
for (const [wave, list] of byWave) {
  appMermaid += `  subgraph w_${id(wave)}["sync-wave ${wave}"]\n`;
  for (const a of list) appMermaid += `    ${id(a.name)}["${a.name}"]\n`;
  appMermaid += "  end\n";
  for (const a of list) appMermaid += `  root --> ${id(a.name)}\n`;
}
appMermaid += "```\n";

const appRows = apps
  .map(
    (a) =>
      `| \`${esc(a.name)}\` | \`${esc(a.namespace)}\` | ${esc(a.wave)} | ${a.helm ? "helm" : "manifests"} | ${esc(a.source)} |`,
  )
  .join("\n");

writeFileSync(
  join(outDir, "applications.md"),
  `---
title: Applications (generated)
description: ArgoCD Application inventory, rendered from cluster/argocd/apps.
---
${BANNER}

All ${apps.length} ArgoCD Applications, from \`cluster/argocd/apps/*.yaml\`. Regenerated on every build, so this always matches what ArgoCD syncs.

## App-of-apps

${appMermaid}

## Inventory

| Application | Namespace | Wave | Type | Source |
| --- | --- | --- | --- | --- |
${appRows}
`,
);

// ------------------------------------------------------------------- Ingresses
const ing = [];
const appsRoot = join(clusterDir, "apps");
for (const f of walk(appsRoot)) {
  for (const doc of parseDocs(f)) {
    const ns = (doc.metadata || {}).namespace || "";
    if (doc.kind === "Ingress") {
      for (const rule of doc.spec?.rules || []) {
        if (!rule.host) continue;
        const svc = rule.http?.paths?.[0]?.backend?.service?.name || "";
        ing.push({ host: rule.host, service: svc, namespace: ns, kind: "Ingress" });
      }
    } else if (doc.kind === "IngressRoute") {
      for (const route of doc.spec?.routes || []) {
        const m = /Host\(`([^`]+)`\)/.exec(route.match || "");
        if (!m) continue;
        ing.push({
          host: m[1],
          service: route.services?.[0]?.name || "",
          namespace: ns,
          kind: "IngressRoute",
        });
      }
    }
  }
}
ing.sort((a, b) => a.host.localeCompare(b.host));

// hostname sweep (catches Helm-values-defined hosts not in structured Ingress objects)
const swept = new Set();
for (const f of walk(appsRoot)) {
  const t = readFileSync(f, "utf8");
  for (const m of t.matchAll(/([a-z0-9][a-z0-9-]*\.arsenikki\.casa)/g)) swept.add(m[1]);
}
const structuredHosts = new Set(ing.map((i) => i.host));
const otherHosts = [...swept].filter((h) => !structuredHosts.has(h)).sort();

let ingMermaid = "```mermaid\nflowchart LR\n";
for (const i of ing) {
  ingMermaid += `  ${id(i.host)}["${i.host}"] --> ${id(i.service + i.namespace)}["${i.service || "?"}<br/>(${i.namespace})"]\n`;
}
ingMermaid += "```\n";

const ingRows = ing
  .map((i) => `| \`${esc(i.host)}\` | \`${esc(i.service)}\` | \`${esc(i.namespace)}\` | ${i.kind} |`)
  .join("\n");

writeFileSync(
  join(outDir, "network.md"),
  `---
title: Ingress & hosts (generated)
description: Hostnames exposed by the cluster, rendered from cluster/apps.
---
${BANNER}

Hosts under \`arsenikki.casa\`, discovered from \`Ingress\` / \`IngressRoute\` objects in \`cluster/apps/\`. See [Networking](/networking/) for the how (Traefik, cert-manager, external-dns).

## Ingress map

${ingMermaid}

## Ingress / IngressRoute objects

| Host | Service | Namespace | Kind |
| --- | --- | --- | --- |
${ingRows}

## Other referenced hostnames

Hosts that appear in manifests (often Helm \`values.yaml\`) without a plain Ingress/IngressRoute object:

${otherHosts.length ? otherHosts.map((h) => `- \`${h}\``).join("\n") : "_none_"}
`,
);

// ----------------------------------------------------------------------- index
writeFileSync(
  join(outDir, "index.md"),
  `---
title: Reference (generated)
description: Auto-generated pages that render directly from the cluster manifests.
---
${BANNER}

These pages are **generated from the manifests** in \`cluster/\` on every build
(\`docs/site/scripts/generate.mjs\`), so they can't drift from what's deployed.
Don't edit them by hand — change the manifests instead.

- **[Applications](/generated/applications/)** — the ${apps.length} ArgoCD Applications + app-of-apps map.
- **[Ingress & hosts](/generated/network/)** — exposed hostnames + ingress map.
`,
);

console.log(
  `[generate] ${apps.length} apps, ${ing.length} ingress hosts, ${otherHosts.length} other hosts -> ${outDir}`,
);
