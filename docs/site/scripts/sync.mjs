// Sync the homelab KB (the git-versioned single source of truth at docs/homelab/,
// which Jeeves agents also read directly) into Starlight's content collection.
// Runs before `dev` and `build` (locally and in the Docker build) so the docs
// markdown lives in exactly one place.
import { cpSync, rmSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const src = fileURLToPath(new URL("../../homelab", import.meta.url)); // docs/homelab
const dest = fileURLToPath(new URL("../src/content/docs", import.meta.url));

rmSync(dest, { recursive: true, force: true });
mkdirSync(dest, { recursive: true });
cpSync(src, dest, { recursive: true });
console.log(`[sync] ${src} -> ${dest}`);
void here;
