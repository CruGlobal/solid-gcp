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

The gem is not published to rubygems.org; consume it straight from GitHub,
pinned to a release tag (the gem lives in this repo's `gem/` subdirectory,
hence `glob:`):

```ruby
gem "solid_gcp", github: "CruGlobal/solid-gcp", tag: "v0.1.0", glob: "gem/*.gemspec"
```

Bundler locks the tag's commit SHA in `Gemfile.lock`, so builds are
reproducible. To upgrade, bump the tag and `bundle update solid_gcp`.
Available versions: [releases](https://github.com/CruGlobal/solid-gcp/releases)
/ [CHANGELOG](../CHANGELOG.md).

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
Cloud Scheduler jobs, Cloud Run service + Job) with this repo's Terraform module,
pinned to the **same tag** as the gem — one tag names one tested gem+infra combination:

```hcl
module "solid_gcp" {
  source = "git::https://github.com/CruGlobal/solid-gcp.git//terraform?ref=v0.1.0"
  # ...
}
```

The module grants all IAM the gem needs (task creation, OIDC token minting for the
invoker SA, `jobs.run`, scheduler management). If you provision by hand instead, see
`../terraform` for the exact roles.

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
| `max_task_bytes` | `900_000` | Max serialized-envelope bytesize; enqueue raises `PayloadTooLarge` above it (Cloud Tasks caps total task size near 1 MB) |

Configure env-driven keys tolerantly (`ENV[...]`, not `ENV.fetch`) so an image
build's `assets:precompile` — which runs with no runtime env — doesn't abort.
`rails g solid_gcp:install` writes a `config/initializers/solid_gcp.rb` embodying
this pattern. Missing required keys raise `SolidGcp::ConfigurationError` (naming
the key) at first dispatch, not a nil crash at boot.

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

A `:local` **server** process also ticks the current env's `recurring.yml` entries
in-process — a dev stand-in for Cloud Scheduler. Each firing goes through the same
enqueue path as `/recurring/:key` (so singleton `on_conflict:` semantics hold). Only
server processes tick; consoles and rake tasks don't. Entries are env-scoped, so
production-only entries stay inert in dev. Arg edits are picked up per firing; schedule
changes need a server restart.

### Cable with the Firebase emulators

Run the whole Cable flow (Firestore touch, custom-token mint, client sign-in + listen)
locally with zero GCP credentials. The recommended path is the prebuilt emulators image
(no local JRE / firebase-tools install):

```bash
docker run --rm -p 8080:8080 -p 9099:9099 \
  ghcr.io/cruglobal/solid-gcp-firebase-emulators:15.23.0
```

Or via docker-compose, mounting your app's `firebase.json` + `firestore.rules` so the
same security rules apply locally (see `emulator-image/README.md`). Without a mounted
config the emulator allows all reads/writes — fine to start.

No-docker fallback (needs a JRE + `firebase-tools`):

```bash
firebase emulators:start --only firestore,auth
```

The emulator loads the app's `firestore.rules` (wired via `firebase.json`) so the same
security rules apply locally. Ports map to localhost either way, so the env vars below
are unchanged. When the firebase CLI spawns your server it sets them; if you run Rails
separately (or use the docker image), export them yourself:

```bash
export FIRESTORE_EMULATOR_HOST=127.0.0.1:8080
export FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099
```

With those set (matching the Admin-SDK convention), the server routes Firestore/Auth at
the emulators and the Stimulus client connects to them — no config needed. `project`
defaults to `demo-solid-gcp` (Firebase's `demo-*` prefix = emulator-only), guarding
against real API calls.

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

In `:local` mode a server process ticks these entries in-process instead (see
[Local development](#local-development)).

## Endpoints

All POST, OIDC-verified, mounted under `/solid_gcp`:

- `/perform` — execute a job. `204` executed (incl. handled retry/discard and
  concurrency discard/block); `503` infra-not-ready (Cloud Tasks retries); `401` bad OIDC.
  Unhandled job exceptions are recorded in `solid_gcp_failed_jobs` and reported, still `204`
  (Active Job owns retries).
- `/launch` — run a Cloud Run Job. `204` accepted, `503` on launch failure.
- `/sweep` — expire stale semaphores, re-dispatch expired blocked jobs.
- `/recurring/:key` — enqueue a recurring entry. `404` unknown key.

## Delivery semantics — jobs must be idempotent

**Solid GCP is at-least-once. Design every job to tolerate running more than once.**

- **Cloud Tasks push (`/perform`)** retries on any non-2xx / timeout. A job whose
  side effects completed but whose response was lost (or that raised after a
  partial write) will be delivered again.
- **Cloud Run Job executions (`perform_via :cloud_run_job`)** add a second source
  of duplication: an execution can **retry after a slow start**, so a single
  execution that GCP reports as "successful" may still run the job body twice
  (observed live). `bin/rails solid_gcp:execute` runs the same receiver path each
  time.

There is no dedup/guard code — idempotency is the app's responsibility. Use
natural keys, `INSERT ... ON CONFLICT`, idempotency tokens, or
`limits_concurrency` where a single-runner invariant matters.

## Instrumentation

Events are published via `ActiveSupport::Notifications` (Rails
`event.solid_gcp` convention). Subscribe with
`ActiveSupport::Notifications.subscribe("perform.solid_gcp") { |*, payload| ... }`.

| Event | Fired when | Payload |
|---|---|---|
| `enqueue.solid_gcp` | Dispatcher enqueues a task | `job_class`, `queue`, `at`, `named` (named Cloud Tasks task?) |
| `perform.solid_gcp` | Receiver executes a delivered envelope | `job_class`, `queue`, `executions`, `outcome` (`:ok`/`:failed`/`:discarded`/`:blocked`/`:not_ready`) |
| `promote.solid_gcp` | A blocked job is promoted when a slot frees | `concurrency_key`, `job_class` |
| `sweep.solid_gcp` | Sweep runs (expire semaphores, redispatch expired blocked jobs) | — |
| `touch.solid_gcp` | Cable stream touch | `stream`, `doc_id`, `sync` (touch vs touch_later), `debounced` |
| `mint_token.solid_gcp` | Cable custom token minted | `streams` (count) |

## Development

```bash
bundle install
bundle exec rake test
```

### Releasing

1. Bump `SolidGcp::VERSION` (`lib/solid_gcp/version.rb`) and move the
   `Unreleased` CHANGELOG entries under the new version.
2. Commit, then `git tag vX.Y.Z && git push origin main vX.Y.Z`.
3. The Release workflow verifies tag == VERSION, runs both suites, and creates
   the GitHub Release with that version's CHANGELOG section as notes.

## License

MIT — see [LICENSE](../LICENSE) at the repo root.
