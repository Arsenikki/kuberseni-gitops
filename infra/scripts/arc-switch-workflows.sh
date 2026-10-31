#!/usr/bin/env bash
# Point the private repos' GitHub Actions workflows at their ARC runner scale sets
# (cluster/apps/arc): every `runs-on: ubuntu-latest` becomes `runs-on: arc-<repo>`,
# and the two jobs that call `gh` (absent from the minimal ARC runner image) get a
# step that installs it. Opens one PR per repo.
#
# Needs: git, gh logged in with the `workflow` scope (pushing .github/workflows
# requires it):  gh auth refresh -s workflow
#
# Usage:
#   infra/scripts/arc-switch-workflows.sh --dry-run          # show the diffs only
#   infra/scripts/arc-switch-workflows.sh                    # all repos
#   infra/scripts/arc-switch-workflows.sh jeeves flock       # selected repos
set -euo pipefail

OWNER=Arsenikki
BRANCH=ci/arc-runners
GH_VERSION=2.103.3 # cli/cli release installed where a job needs gh
DEFAULT_REPOS=(jeeves paseo-homelab resepti flock coachi captain-core)

dry_run=false
repos=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    -h | --help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *) repos+=("$arg") ;;
  esac
done
[[ ${#repos[@]} -gt 0 ]] || repos=("${DEFAULT_REPOS[@]}")

if ! $dry_run; then
  scopes=$(gh api -i user 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')
  if [[ -n "$scopes" && "$scopes" != *workflow* ]]; then
    echo "gh token lacks the 'workflow' scope (has: $scopes). Run: gh auth refresh -s workflow" >&2
    exit 1
  fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# insert_before FILE ANCHOR — inserts the gh install step (from stdin) before the
# line that exactly equals ANCHOR; fails if the anchor isn't there exactly once.
insert_gh_step() {
  local file=$1 anchor=$2 n
  n=$(grep -cxF -- "$anchor" "$file" || true)
  if [[ "$n" != 1 ]]; then
    echo "  ! expected exactly one line '$anchor' in $file, found $n" >&2
    return 1
  fi
  awk -v anchor="$anchor" -v ver="$GH_VERSION" '
    $0 == anchor {
      print "      - name: Install gh (the ARC runner image does not ship it)"
      print "        run: |"
      print "          curl -fsSL \"https://github.com/cli/cli/releases/download/v" ver "/gh_" ver "_linux_amd64.tar.gz\" \\"
      print "            | sudo tar -xz -C /usr/local --strip-components=1"
      print "          gh --version"
    }
    { print }
  ' "$file" >"$file.new" && mv "$file.new" "$file"
}

for repo in "${repos[@]}"; do
  echo "== $OWNER/$repo"
  # Re-runnable: a repo whose branch was already pushed (earlier run) is skipped.
  if gh api "repos/$OWNER/$repo/git/ref/heads/$BRANCH" --silent 2>/dev/null; then
    gh pr view "$BRANCH" --repo "$OWNER/$repo" --json url -q .url 2>/dev/null ||
      echo "  ! $BRANCH exists but has no PR — open one by hand, or delete the branch to redo" >&2
    echo "  $BRANCH already pushed — skipping"
    continue
  fi
  dir="$work/$repo"
  gh repo clone "$OWNER/$repo" "$dir" -- --quiet --depth 1
  pushd "$dir" >/dev/null
  git switch --quiet -c "$BRANCH"

  shopt -s nullglob
  files=(.github/workflows/*.yml .github/workflows/*.yaml)
  shopt -u nullglob
  for f in "${files[@]}"; do
    sed -E -i "s/^([[:space:]]*runs-on:[[:space:]]*)ubuntu-latest[[:space:]]*$/\1arc-$repo/" "$f"
  done

  case "$repo" in
    jeeves) insert_gh_step .github/workflows/soak-promote.yml "      - name: Evaluate soak gate" ;;
    coachi) insert_gh_step .github/workflows/preview.yml "      - name: Comment on the PR" ;;
  esac

  if left=$(grep -nE 'runs-on:.*ubuntu' "${files[@]}"); then
    echo "  ! still targets a GitHub-hosted runner — fix by hand:" >&2
    echo "$left" >&2
    exit 1
  fi
  if git diff --quiet; then
    echo "  nothing to change (already on arc-$repo?)"
    popd >/dev/null
    continue
  fi

  git --no-pager diff --stat
  if $dry_run; then
    git --no-pager diff
    popd >/dev/null
    continue
  fi

  git commit --quiet -am "ci: run on the homelab ARC runners (arc-$repo)"
  git push --quiet -u origin "$BRANCH"
  gh pr create --repo "$OWNER/$repo" --base "$(git rev-parse --abbrev-ref origin/HEAD | sed 's|^origin/||')" --head "$BRANCH" \
    --title "ci: run on the homelab ARC runners (arc-$repo)" \
    --body "Moves every job from GitHub-hosted \`ubuntu-latest\` (private-repo minutes) to the self-hosted ARC scale set \`arc-$repo\` in the homelab cluster (kuberseni-gitops \`cluster/apps/arc\`). Runner pods are ephemeral and scale to zero; Docker builds use a docker-in-docker sidecar. Jobs that call \`gh\` install it first, since the ARC runner image is minimal.

Merge after the ARC runners are live (the \`arc-$repo\` scale set shows under Settings → Actions → Runners)."
  popd >/dev/null
done
