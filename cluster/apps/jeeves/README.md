# Jeeves

[Jeeves](https://github.com/Arsenikki/jeeves) (private) publishes two Helm charts
to `oci://ghcr.io/arsenikki/charts` on every release: `jeeves` (one instance, with
its agent prompts) and `jeeves-board` (the shared board). The
templates and prompts live in the jeeves repo (`deploy/charts/`); this directory
holds only the values for each deployment:

| Argo app (`cluster/argocd/apps/`) | Chart          | Namespace     | Values                    |
| --------------------------------- | -------------- | ------------- | ------------------------- |
| `jeeves-dev.yaml`                 | `jeeves`       | `jeeves-dev`  | `values-dev.yaml`         |
| `jeeves.yaml`                     | `jeeves`       | `jeeves-prod` | `values-prod.yaml`        |
| `jeeves-board.yaml`               | `jeeves-board` | `jeeves-board`| `values-board.yaml`       |

Chart defaults hold the shared config; these files list only what differs.

## Versions

Each Argo app pins `targetRevision` (chart `X.Y.Z` runs image `vX.Y.Z`). Renovate
bumps it (`.github/renovate.json5`):

- **jeeves-dev** auto-merges every release: dev is the edge channel.
- **prod + board** get one grouped PR. Merging it is the promotion, so merge it
  once the version has proven out on dev.

To run a pre-merge candidate on dev, set `image.tag` in `values-dev.yaml` to a
branch edge image (`<semver>-<branch>-<shortsha>`, built with
`gh workflow run build.yml --ref <branch>` in the jeeves repo).

## Gotchas

- The chart is private, so the CI "Render ArgoCD diff" can't render these apps
  (`argocd-diff-preview/ignore`). Check a template change with
  `helm template` in the jeeves repo instead.
- ArgoCD reads the chart with the `arsenikki-charts` OCI repository credential
  (`cluster/bootstrap/argocd/values.yaml`, 1Password `github-packages-ro`).
- The Namespace objects are rendered by the charts with `Prune=false`: they hold
  the NATS and board SQLite PVCs.
