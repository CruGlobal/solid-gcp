# Solid GCP dummy app

Guinea-pig Rails app that exercises the [`solid_gcp`](../gem) gem end-to-end
before Flightdeck adopts it. It mirrors Flightdeck's real Active Job patterns:
a retry ladder, a delayed self-escalation, a discard singleton, a blocking
per-user job, an always-failing job, and a long "import" that runs as a Cloud
Run Job.

- App name / module: `Dummy`
- Ruby 3.4.7 (asdf; see repo-root `.tool-versions`), Rails 8.1.x, SQLite.
- Gem wired via `gem "solid_gcp", path: "../gem"`.

## Demo jobs (`app/jobs/`)

| Job | Proves |
|---|---|
| `PingJob` | trivial execution; writes a `JobRun` row |
| `FlakyWebhookJob` | `retry_on` ladder (`:polynomially_longer`); fails twice, succeeds on the 3rd attempt |
| `DoomedJob` | unhandled failure recorded in `solid_gcp_failed_jobs`; `retry_job` re-runs it |
| `SingletonTickJob` | `limits_concurrency ... on_conflict: :discard` — 2nd delivery dropped while 1st holds the slot |
| `PerUserDigestJob` | `limits_concurrency` per-user with default `:block` — 2nd delivery parked, promoted FIFO |
| `EscalationStepJob` | delayed enqueue via `set(wait:)` — self-reschedules 3 steps, 5s apart |
| `FakeImportJob` | `perform_via :cloud_run_job` — routed to `/solid_gcp/launch` (the jira-import stand-in) |

Every job writes `JobRun` rows (`job_class`, `args`, `note`, `ran_at`) so
executions are observable in the dashboard.

## Local demo (no GCP)

Development uses `config.solid_gcp.mode = :local` (in-process threaded delivery;
delays actually elapse; OIDC skipped).

```bash
bin/rails db:prepare
bin/rails server
# open http://localhost:3000
```

Click a demo button, then refresh: `JobRun` rows appear as the background
threads deliver the jobs. `EscalationStepJob`'s steps land ~5s apart (delays are
real in `:local` mode). Failed jobs show in the "Failed jobs" table with a
**Retry** button.

Quick sanity check without the browser:

```bash
bin/rails runner 'PingJob.perform_later("hi"); sleep 1; puts JobRun.last&.note'
```

### `FakeImportJob` in local mode

`perform_via :cloud_run_job` normally dispatches to `/launch`, which calls the
Cloud Run Admin API. In `:local` mode the gem executes launch envelopes
in-process instead — exactly what `bin/rails solid_gcp:execute` does on a real
Cloud Run Job — so no GCP creds are needed.

## Tests

```bash
bin/rails test
```

Test env uses `config.solid_gcp.mode = :test` (in-memory backend). Tests enqueue
through the adapter and drain via `SolidGcp::Testing.drain`, asserting the retry
ladder, failed-job recording + retry, discard, block + FIFO promotion, and
delayed rescheduling. One controller test POSTs a real envelope to
`/solid_gcp/perform` end-to-end (OIDC disabled in test).

## How it would deploy

Production uses `config.solid_gcp.mode = :cloud_tasks`, all env-driven
(`config/environments/production.rb`):

```
SOLID_GCP_PROJECT, SOLID_GCP_LOCATION, SOLID_GCP_PUSH_BASE_URL,
SOLID_GCP_INVOKER_SA, SOLID_GCP_CLOUD_RUN_JOB
```

1. **Image** — `Dockerfile` builds a Cloud Run image. The *same* image serves
   two roles: the Cloud Run **service** (default CMD boots the server; Cloud
   Tasks / Cloud Scheduler POST to `/solid_gcp/*`) and the Cloud Run **Job** for
   `FakeImportJob` (command overridden to `bin/rails solid_gcp:execute`, reading
   `SOLID_GCP_ENVELOPE`).
   *Caveat:* the `path:` gem dependency lives outside the Docker build context;
   a real build needs the published gem or a repo-root build context (see the
   Dockerfile header). Flightdeck will use the published gem.
2. **Infra** — the Terraform module in `../terraform` provisions Cloud Tasks
   queues, invoker/enqueuer service accounts + IAM, Cloud Run service + Job, and
   Artifact Registry (sandbox project `cru-mattdrees-sandbox-poc`).
3. **Recurring** — `config/recurring.yml` (Solid Queue format) is synced to
   Cloud Scheduler with `bin/rails solid_gcp:scheduler:sync`; each entry POSTs
   (OIDC) to `/solid_gcp/recurring/<key>`.

