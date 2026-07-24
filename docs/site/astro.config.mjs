import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import mermaid from "astro-mermaid";

// The homelab docs site. Content is the git-versioned KB at docs/homelab/
// (synced into src/content/docs at build time by scripts/sync.mjs). Public repo,
// public site — no secrets belong in these pages.
export default defineConfig({
  site: "https://docs.arsenikki.casa",
  integrations: [
    // astro-mermaid must run before Starlight so ```mermaid fences render as diagrams.
    mermaid({ theme: "default", autoTheme: true }),
    starlight({
      title: "Homelab",
      description:
        "Knowledge base for the kuberseni Talos Kubernetes homelab — infrastructure, GitOps, apps, and runbooks.",
      sidebar: [
        { label: "Overview", link: "/" },
        { label: "Infrastructure", items: ["cluster", "networking", "storage"] },
        { label: "Platform", items: ["gitops", "secrets", "applications"] },
        { label: "Automation", items: ["jeeves"] },
        { label: "Runbooks", items: [{ autogenerate: { directory: "runbooks" } }] },
      ],
    }),
  ],
});
