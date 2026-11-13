# digests

Daily personal AI digest. Source: <https://github.com/Arsenikki/digests>.

At 06:30 UK time the CronJob:
1. Reads personal Gmail (last 24h), Google Calendar, Google Tasks and the configured news feeds.
2. Reads the work calendar through the **free/busy API only**, so it sees "Busy (work)" blocks with times and nothing else.
3. Hands each AI step to the shared **paseo-apps** daemon: one agent sorts all of the day's emails, then one each for news and the overview, plus one per reply draft. Each runs as a one-shot Gemini agent (`antigravity/gemini-3.8-flash-low` for triage, `-high` for writing). It uses `paseo run --output-schema` for validated JSON and archives its agents at the end of the run.
4. Adds a **🛠 Shipped** section listing PRs merged in the last 24h, from the Jeeves board activity log (`flock:8099`). Renovate bumps are collapsed into a count.
5. Commits `Daily/YYYY-MM-DD-digest.md` to the private `Arsenikki/daily-digests` repo (opened as an Obsidian vault and synced by the Obsidian Git plugin), then posts a short summary with a link to the note to Telegram (@CasaAlertingBot).

Work email is out of scope here. It's summarised on the work laptop by the `/good-morning` Claude Code skill (`digests collect --profile work`).

## Secrets: 1Password item `digests` (vault `homelab`)

| Field | What |
|---|---|
| `google_token_personal` | token JSON from `digests auth --profile personal` (OAuth app must be "In production", or the refresh token expires after 7 days) |
| `github_app_id`, `github_app_installation_id`, `github_app_private_key` | GitHub App with Contents read/write, installed on `Arsenikki/daily-digests` only. The job mints a 1-hour token per run. |

The Paseo password comes from `paseo-apps-password` (same as resepti), and Telegram from the existing `CasaBot (Telegram)` item. Gemini quota is your AI Pro plan's, shared with everything else on paseo-apps.

## Operations

- Run now: `kubectl create job --from=cronjob/digests manual-$(date +%s) -n digests`
- Turn on Gmail drafts and Google Tasks: set `actions.enabled: true` in `configmap.yaml`.
- Upgrade: tag `vX.Y.Z` in the app repo (CI publishes the image), then bump the tag in `cronjob.yaml`.
