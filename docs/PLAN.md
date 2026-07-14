# Solid GCP — product plan

GCP-centric Active Job backend replacing Solid Queue, enabling true scale-to-zero for
both the Rails app (Cloud Run) and the database (self-hosted Neon, ../neon-gcp).
Target app: ../flightdeck. This repo: the `solid_gcp` gem + GCP infra (terraform) +
a dummy Rails app proving the contracts before folding into Flightdeck.

## Why Solid Queue can't scale to zero

Solid Queue = always-running pollers (dispatcher + workers) against an always-on
Postgres. Idle app still burns a Cloud Run instance and keeps Neon awake (0.1s polls).

## Core idea: push, don't poll

**Cloud Tasks carries the trigger; Postgres is the source of truth only while awake.**

- `perform_later` → create a Cloud Tasks task (HTTP push, OIDC-signed) targeting the
  app's `/solid_gcp/perform` endpoint. Payload = standard Active Job serialization.
- Cloud Run scales from zero on the push; the job's own DB use wakes Neon.
- `set(wait:)` / `enqueue_at` → Cloud Tasks `scheduleTime`. No dispatcher process.
- Idle system: zero Cloud Run instances, Neon suspended, tasks parked in Cloud Tasks
  (a fully managed queue that costs ~nothing at rest).

### Component map (Solid Queue → Solid GCP)

| Solid Queue | Solid GCP |
|---|---|
| dispatcher + scheduled_executions | Cloud Tasks `scheduleTime` |
| workers polling ready_executions | Cloud Tasks HTTP push → Rails engine endpoint |
| queues (default/ingest) | 1:1 Cloud Tasks queues; per-queue rate/concurrency limits give ingest-storm containment (Flightdeck FD-315 requirement) |
| recurring.yml + scheduler process | recurring.yml (same format) synced to Cloud Scheduler → `/solid_gcp/recurring/<key>` |
| concurrency controls (`limits_concurrency`) | same DSL, Postgres semaphores + blocked-jobs table (see below) |
| failed_executions | `solid_gcp_failed_jobs` table + retry API |
| long/heavy jobs in workers | `perform_via :cloud_run_job` → Cloud Run Jobs execution (jira import) |
| supervisor/maintenance process | self-scheduling sweep tasks (no cron, no idle DB wakes) |

## Execution semantics

`/solid_gcp/perform` (engine controller):
1. Verify OIDC token (google-id-token verification: issuer, audience, expected SA email).
   Required because Flightdeck's Cloud Run service is public.
2. Deserialize; acquire concurrency semaphore if the job class declares one.
3. Execute via `ActiveJob::Base.execute`.
4. Outcome → HTTP status:
   - success, or handled by `retry_on`/`discard_on` → 2xx. `retry_on` re-enqueues
     itself as a *new* task with computed `scheduleTime`; Active Job retry semantics
     (`executions`, `:polynomially_longer`, lambda waits, blocks, `retry_job`) work
     unmodified because they ride on the adapter's `enqueue_at`.
   - unhandled app exception → record in `solid_gcp_failed_jobs`, `Rails.error.report`,
     return 2xx (Cloud Tasks must NOT also retry; Active Job owns retries). Mirrors
     Solid Queue's fail-fast.
   - infra-not-ready (DB unreachable/waking, deploy race) → 503; Cloud Tasks retries
     with backoff. This is what absorbs Neon's 70–100s cold connect (long
     `connect_timeout` in DATABASE_URL + task retry as the backstop).

Delivery is at-least-once (Cloud Tasks contract; same as Solid Queue in practice).
Jobs must stay idempotent-ish — no regression vs today.

## Concurrency controls (`limits_concurrency`)

Flightdeck uses: static key + `on_conflict: :discard` (2 singletons), lambda per-arg
key + default **block** (NotificationDeliveryJob). Reimplemented on Postgres — safe
for scale-to-zero because semaphores are only touched at enqueue time (web request,
DB already awake) and execution time (job wakes DB anyway):

- `solid_gcp_semaphores` (key, value, expires_at) — claim with atomic upsert/decrement,
  like SolidQueue::Semaphore.
- Enqueue path: limit reached → `:discard` drops silently; `:block` inserts into
  `solid_gcp_blocked_jobs` (serialized payload, key, expires_at) instead of creating a task.
- Release path: job completion releases semaphore and immediately promotes the oldest
  blocked job for that key (creates its Cloud Tasks task). FIFO, low latency.
- Crash safety: semaphores/blocked rows carry `expires_at` (`duration`, default 15 min).
  On every acquire/block we lazily enqueue ONE self-scheduled "sweep" task at the
  earliest expiry (deduped via Cloud Tasks named task). Sweep expires stale semaphores
  and re-dispatches expired blocked jobs. No fixed cron → no idle DB wakes.

## Cloud Run Jobs mode (jira import)

Job class declares `perform_via :cloud_run_job` (gem DSL; default `:http_push`).
Enqueue still goes through Cloud Tasks (keeps delays + launch retries), but targets
`/solid_gcp/launch`, which calls the Cloud Run Admin API `jobs.run` with container
overrides passing the serialized payload (env var). The Cloud Run Job runs the same
image with command `bin/rails solid_gcp:execute` — up to 24h runtime, dedicated
CPU/memory, /tmp sized for attachment downloads. Same semaphore machinery applies.
Failure of the execution → recorded in failed_jobs by the runner process itself.

## Recurring

`config/recurring.yml` (Solid Queue's format, incl. `command:` entries) →
`rake solid_gcp:scheduler:sync` idempotently upserts Cloud Scheduler jobs, each hitting
`/solid_gcp/recurring/<key>` (OIDC), which enqueues the class through normal machinery
(so singleton `on_conflict: :discard` applies). Known cost: Flightdeck's two per-minute
jobs wake the service every minute — inherent to the workload, flagged for later rework;
scale-to-zero still wins nights/weekends only if those are rethought (out of scope here).

## Local development / test

- `:solid_gcp_local` adapter variant: in-process thread scheduler POSTs to the local
  server (same engine endpoint, OIDC skipped) — full-fidelity demo without GCP.
- Test mode: `SolidGcp::Testing` in-memory queue with `perform_enqueued_jobs`-style
  helpers; standard `:test` adapter continues to work.

## Infra (terraform/)

Module for the dummy app (later reusable for Flightdeck): Cloud Tasks queues
(default, ingest, mailers), invoker + enqueuer service accounts, IAM, Cloud Scheduler
jobs from recurring.yml, Cloud Run service + Cloud Run Job (import), Artifact Registry.
Sandbox project: cru-mattdrees-sandbox-poc.

## Repo layout

```
gem/          solid_gcp gem (engine, adapter, concurrency, launcher, rake tasks)
dummy/        dummy Rails app (guinea pig; also the integration-test harness)
terraform/    GCP infra module + sandbox instantiation
docs/         this plan, design notes
```

## Build phases

1. **Gem core** — adapter (enqueue/enqueue_at), payload envelope, engine + OIDC
  verification, executor, failed jobs, migrations generator, unit tests (minitest).
2. **Concurrency controls** — semaphores, blocked jobs, discard/block, sweep tasks.
3. **Cloud Run Jobs mode + recurring sync** — launcher, `solid_gcp:execute`,
  scheduler sync rake task.
4. **Dummy app** — representative jobs mirroring Flightdeck's patterns (retry ladder,
  delayed escalation, discard singleton, blocking per-user, fake long import via
  cloud_run_job), local adapter demo, integration tests.
5. **Terraform + real GCP smoke test** (sandbox project).
6. Later, separate effort: fold into Flightdeck (swap adapter, keep queue.yml isolation
  semantics via Cloud Tasks queue configs, decide Solid Cache/Cable fate).

## Unresolved questions

- Gem name `solid_gcp` OK? (adapter `:solid_gcp`)
- Semaphore default `duration` 15 min OK? (SQ default is 3 min; jira import runs hours —
  import path should set explicit long duration or rely on its existing controller CAS)
- Flightdeck per-minute recurring jobs: accept minute-ly wakes for now?
- Solid Cache/Cable out of scope for this repo — agreed?
- Terraform here vs cru-terraform conventions — sandbox-only OK for now?
