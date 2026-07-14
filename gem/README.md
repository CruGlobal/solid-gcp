# Solid GCP

A GCP-centric Active Job backend that replaces Solid Queue and enables true
scale-to-zero for a Rails app on Cloud Run (and its database).

**Push, don't poll.** `perform_later` creates a [Cloud Tasks](https://cloud.google.com/tasks)
task (HTTP push, OIDC-signed) targeting a mounted Rails engine endpoint. Cloud Run
scales from zero on the push; no dispatcher or worker processes poll the database.
Concurrency controls (`limits_concurrency`) are reimplemented on Postgres semaphores,
touched only at enqueue/execution time. Long jobs run as Cloud Run Jobs; recurring
jobs are synced to Cloud Scheduler.

| Solid Queue | Solid GCP |
|---|---|
| dispatcher + scheduled_executions | Cloud Tasks `scheduleTime` |
| workers polling ready_executions | Cloud Tasks HTTP push → engine endpoint |
| queues | 1:1 Cloud Tasks queues (per-queue rate/concurrency limits) |
| recurring.yml + scheduler process | recurring.yml synced to Cloud Scheduler |
| concurrency controls | same DSL, Postgres semaphores + blocked-jobs table |
| failed_executions | `solid_gcp_failed_jobs` table + retry API |
| long jobs in workers | `perform_via :cloud_run_job` → Cloud Run Jobs |

## Install

Add to your Gemfile:

```ruby
gem "solid_gcp"
```

Mount the engine (must be at `/solid_gcp`):

```ruby
# config/routes.rb
mount SolidGcp::Engine => "/solid_gcp"
```

Set the adapter and configure:

```ruby
# config/application.rb (or an environment file)
config.active_job.queue_adapter = :solid_gcp

config.solid_gcp.mode                    = :cloud_tasks
config.solid_gcp.project                 = "my-gcp-project"
config.solid_gcp.location                = "us-central1"
config.solid_gcp.push_base_url           = "https://my-app.example.com"
config.solid_gcp.invoker_service_account = "invoker@my-gcp-project.iam.gserviceaccount.com"
config.solid_gcp.cloud_run_job_name      = "import-runner" # optional default
```

`config.solid_gcp` is the live `SolidGcp.config` object, so any key below can be set
on it directly.

Generate and run the migration (creates the three tables):

```bash
bin/rails g solid_gcp:install
bin/rails db:migrate
```

Provision the GCP infrastructure (Cloud Tasks queues, service accounts + IAM,
Cloud Scheduler jobs, Cloud Run service + Job, Artifact Registry) with the Terraform
module in `../terraform`.

## Configuration reference

| Key | Default | Notes |
|---|---|---|
| `mode` | `:cloud_tasks` | `:cloud_tasks` \| `:local` \| `:test` |
| `project` | `nil` | GCP project id |
| `location` | `nil` | GCP region |
| `push_base_url` | `nil` | Public base URL of the Cloud Run service |
| `queue_prefix` | `"solid-gcp-"` | Cloud Tasks queue = prefix + AJ queue name |
| `invoker_service_account` | `nil` | SA email in task OIDC token + verified on receipt |
| `oidc_audience` | `push_base_url` | OIDC audience |
| `verify_oidc` | `true` in production, else `false` | OIDC verification toggle |
| `default_concurrency_duration` | `15.minutes` | Semaphore lease (crash safety) |
| `cloud_run_job_name` | `nil` | Cloud Run Job for `perform_via :cloud_run_job` |
| `connects_to` | `nil` | Passed to `SolidGcp::Record.connects_to` |
| `recurring_file` | `"config/recurring.yml"` | Recurring schedule file |

## Concurrency controls

Same DSL as Solid Queue; enforcement happens at delivery time in the receiver
(uniform for immediate and delayed jobs):

```ruby
class NotificationDeliveryJob < ApplicationJob
  limits_concurrency key: ->(user_id) { user_id }, to: 1, on_conflict: :block
  def perform(user_id) = ...
end

class SyncSingletonJob < ApplicationJob
  limits_concurrency key: "sync", to: 1, on_conflict: :discard
  def perform = ...
end
```

- `key` may be a String/Symbol or a Proc that receives the job arguments.
- `on_conflict: :discard` drops the job silently when the limit is reached;
  `:block` parks it in `solid_gcp_blocked_jobs` and promotes it (FIFO) when a slot frees.
- Semaphores and blocked rows carry `expires_at`; a self-scheduled sweep task expires
  stale rows and re-dispatches expired blocked jobs. No cron, so no idle DB wakes.

Solid GCP refuses to boot if Solid Queue is also loaded (both define `limits_concurrency`).

## Local development

Run the full flow in-process without GCP credentials:

```ruby
config.solid_gcp.mode = :local
```

Enqueued jobs are delivered by an in-process thread scheduler that honors delays and
runs the same receiver path. OIDC verification is off by default outside production.

## Cloud Run Jobs (long jobs)

Declare the execution mode on the job class:

```ruby
class JiraImportJob < ApplicationJob
  perform_via :cloud_run_job, job: "import-runner" # job: overrides config.cloud_run_job_name
  def perform(import_id) = ...
end
```

Enqueue still goes through Cloud Tasks (delays + launch retries) but targets `/launch`,
which calls the Cloud Run Admin API `jobs.run`, passing the serialized envelope via the
`SOLID_GCP_ENVELOPE` env var. The Cloud Run Job runs the same image with:

```bash
bin/rails solid_gcp:execute
```

which runs the exact receiver path (semaphores, failed-job recording). It exits non-zero
on infra-not-ready so the Cloud Run Job execution retries per its own retry config.

## Recurring jobs

Use Solid Queue's `config/recurring.yml` format (`class:`/`command:`, `args:`, `queue:`,
`schedule:`). Sync it to Cloud Scheduler idempotently:

```bash
bin/rails solid_gcp:scheduler:sync
```

Each entry becomes one Cloud Scheduler job (`solid-gcp-<key>`) POSTing (OIDC) to
`/solid_gcp/recurring/<key>`, which enqueues through the normal machinery (so singleton
`on_conflict: :discard` still applies). Schedules are parsed with `fugit`; sub-minute
schedules are rejected since Cloud Scheduler is minute-granular.

## Endpoints

All POST, OIDC-verified, mounted under `/solid_gcp`:

- `/perform` — execute a job. `204` executed (incl. handled retry/discard and
  concurrency discard/block); `503` infra-not-ready (Cloud Tasks retries); `401` bad OIDC.
  Unhandled job exceptions are recorded in `solid_gcp_failed_jobs` and reported, still `204`
  (Active Job owns retries).
- `/launch` — run a Cloud Run Job. `204` accepted, `503` on launch failure.
- `/sweep` — expire stale semaphores, re-dispatch expired blocked jobs.
- `/recurring/:key` — enqueue a recurring entry. `404` unknown key.

## Development

```bash
bundle install
bundle exec rake test
```
