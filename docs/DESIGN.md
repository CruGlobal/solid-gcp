# Solid GCP — design spec (v1)

Implementation contract for the `solid_gcp` gem. Read docs/PLAN.md first for rationale.

## Gem layout (`gem/`)

```
gem/
  solid_gcp.gemspec          # deps: rails >= 7.1, google-cloud-tasks,
                             # google-cloud-run-v2, google-cloud-scheduler,
                             # googleauth, fugit
  lib/solid_gcp.rb
  lib/solid_gcp/version.rb
  lib/solid_gcp/engine.rb            # Rails::Engine, isolate_namespace SolidGcp
  lib/solid_gcp/configuration.rb
  lib/solid_gcp/concurrency_controls.rb   # limits_concurrency DSL mixin
  lib/solid_gcp/execution_mode.rb         # perform_via DSL mixin
  lib/solid_gcp/envelope.rb
  lib/solid_gcp/receiver.rb
  lib/solid_gcp/dispatcher.rb             # routes to cloud_tasks/local backend
  lib/solid_gcp/backends/cloud_tasks.rb
  lib/solid_gcp/backends/local.rb
  lib/solid_gcp/backends/test.rb
  lib/solid_gcp/cloud_run_job_launcher.rb
  lib/solid_gcp/oidc_verifier.rb
  lib/solid_gcp/recurring.rb              # recurring.yml parsing (fugit)
  lib/solid_gcp/scheduler_sync.rb         # Cloud Scheduler upserts
  lib/solid_gcp/testing.rb                # test helpers
  lib/active_job/queue_adapters/solid_gcp_adapter.rb
  lib/tasks/solid_gcp.rake                # solid_gcp:execute, solid_gcp:scheduler:sync
  app/models/solid_gcp/record.rb          # abstract, connects_to via config
  app/models/solid_gcp/semaphore.rb
  app/models/solid_gcp/blocked_job.rb
  app/models/solid_gcp/failed_job.rb
  app/models/solid_gcp/recurring_command_job.rb  # ActiveJob that evals command:
  app/controllers/solid_gcp/tasks_controller.rb  # perform/launch/sweep/recurring
  config/routes.rb
  lib/generators/solid_gcp/install/...    # copies create_solid_gcp_tables migration
  test/                                   # minitest; sqlite3 for AR-backed tests
```

## Configuration

`SolidGcp.config` (settable via `config.solid_gcp.*` in Rails):

| key | default | notes |
|---|---|---|
| `mode` | `:cloud_tasks` | `:cloud_tasks` \| `:local` \| `:test` |
| `project`, `location` | nil | GCP project id, region |
| `push_base_url` | nil | public base URL of the Cloud Run service |
| `queue_prefix` | `"solid-gcp-"` | Cloud Tasks queue = prefix + AJ queue name |
| `invoker_service_account` | nil | SA email used in task OIDC + verified on receipt |
| `oidc_audience` | push_base_url | |
| `verify_oidc` | true in production | false for `:local` |
| `default_concurrency_duration` | 15.minutes | semaphore lease |
| `cloud_run_job_name` | nil | Cloud Run Job to run for `perform_via :cloud_run_job` (per-class override via `perform_via :cloud_run_job, job: "name"`) |
| `connects_to` | nil | passed to SolidGcp::Record |
| `recurring_file` | `config/recurring.yml` | |

## Adapter

`ActiveJob::QueueAdapters::SolidGcpAdapter`:
- `enqueue(job)` / `enqueue_at(job, timestamp)` → `SolidGcp::Dispatcher.dispatch(job, at:)`.
- `enqueue_after_transaction_commit?` → true.
- No enqueue-time concurrency check: **all concurrency enforcement happens at
  delivery time** in Receiver (uniform for immediate + delayed jobs; see PLAN).

## Envelope (task body, JSON)

```json
{ "solid_gcp": 1, "job": { ...ActiveJob#serialize... }, "dispatched_at": "iso8601" }
```
Same envelope for /perform and /launch and the Cloud Run Job env var.

## Endpoints (engine routes, all POST, OIDC-verified)

- `/perform` — Receiver.receive(envelope). Responses:
  - 204: executed (success, or failure fully handled by AJ retry/discard, or
    concurrency-discarded/blocked).
  - 503: infra-not-ready (`ActiveRecord::ConnectionNotEstablished`,
    `PG::ConnectionBad`-ish, `SolidGcp::NotReady`) → Cloud Tasks retries.
  - 401: bad/missing OIDC.
  - Unhandled job exception: recorded in failed_jobs + `Rails.error.report(handled: false)`
    → still 204 (Cloud Tasks must not double-retry; AJ owns retries).
- `/launch` — same envelope; calls CloudRunJobLauncher. 204 on launch accepted,
  503 on launch API failure (Cloud Tasks retries the launch).
- `/sweep` — expire semaphores, re-dispatch expired blocked jobs; reschedule self
  if outstanding rows remain.
- `/recurring/:key` — look up entry in recurring.yml; enqueue its class/args (or
  RecurringCommandJob for `command:` entries). 404 unknown key.

## Receiver algorithm

```
deserialize job (ActiveJob::Base.deserialize + deserialize arguments)
if job.class.concurrency_limited?
  key = job.concurrency_key          # static or instance_exec'd lambda(*arguments)
  unless Semaphore.wait(key, limit: job.concurrency_limit, duration: ...)
    case on_conflict
    when :discard then return :discarded            # 204
    when :block   then BlockedJob.create!(...); SweepScheduler.ensure; return :blocked
    end
  end
end
begin
  ActiveJob::Base.execute(envelope["job"])   # runs retry_on/discard_on machinery
rescue infra-errors => raise NotReady        # → 503 (semaphore released; job redelivered)
rescue => e
  FailedJob.record!(envelope, e); Rails.error.report(e, handled: false)
ensure
  if acquired
    Semaphore.signal(key)
    BlockedJob.release_one(key)              # promote oldest blocked → dispatch task
  end
end
```

Note: `retry_on`'s internal re-enqueue goes through the adapter → new task with
scheduleTime; `executions` counter rides in the serialized job. `retry_job` works too.

## Concurrency DSL (`SolidGcp::ConcurrencyControls`)

Included into `ActiveJob::Base` by the engine. Mirrors Solid Queue's API:

```ruby
limits_concurrency key:, to: 1, duration: SolidGcp.config.default_concurrency_duration,
                   on_conflict: :block   # :block | :discard
```
- `key` may be a String/Symbol or a Proc receiving the job arguments
  (`instance_exec(*arguments, &key)`), stringified like SQ
  (param-ize GlobalID-able objects the same way SQ does: use `to_gid_param`-ish;
  simple `.to_s` of each part joined with `/` is acceptable for v1).
- Class predicate `concurrency_limited?`; instance `concurrency_key`.
- Do not load if `limits_concurrency` already defined (Solid Queue present) — raise
  a clear error instead; the two backends must not be mixed.

## Semaphore semantics (mirror SolidQueue::Semaphore)

Table `solid_gcp_semaphores(key uniq, value int, expires_at, timestamps)`.
- `wait(key, limit:, duration:)` → attempt create with value=limit-1, else atomic
  `UPDATE ... SET value = value - 1 WHERE key = ? AND value > 0` (+ bump expires_at).
  True if a row was created/updated.
- `signal(key)` → `UPDATE ... SET value = value + 1 WHERE value < limit` (bump expires_at).
- Sweep deletes rows with `expires_at < now` (crashed holders).
Portable SQL (works on sqlite + postgres); wrap create-race in rescue-unique-retry.

`solid_gcp_blocked_jobs(concurrency_key idx, serialized_envelope jsonb/text, expires_at, timestamps)`
- `release_one(key)`: oldest row for key → destroy + Dispatcher.dispatch_envelope.
- Sweep: rows with expires_at < now get re-dispatched (they retry semaphore at delivery).

`solid_gcp_failed_jobs(active_job_id, job_class, queue_name, serialized_envelope,
error_class, error_message, backtrace text, failed_at)` — `#retry_job` re-dispatches
and destroys; `#discard` destroys.

## Sweep scheduling

`SweepScheduler.ensure_scheduled(at:)`: in cloud_tasks mode create a **named** task
`sweep-<minute-bucket>` (dedup by name; ALREADY_EXISTS → ok) on the default queue
targeting /sweep. In local mode, a Thread timer. Called whenever a semaphore is
claimed or a job blocks.

## Cloud Run Jobs

- `perform_via :cloud_run_job` class DSL (`SolidGcp::ExecutionMode` mixin). Dispatcher
  routes such jobs' tasks to `/launch` instead of `/perform`.
- `CloudRunJobLauncher.launch(envelope)`: `Google::Cloud::Run::V2::Jobs::Client#run_job`
  with `overrides.container_overrides[0].env = [{name: "SOLID_GCP_ENVELOPE", value: json}]`.
- `rake solid_gcp:execute`: reads `ENV["SOLID_GCP_ENVELOPE"]`, runs the exact Receiver
  path (semaphores, failed-job recording). Non-zero exit on infra-not-ready so the
  Cloud Run Job execution retries per its own retry config.

## Recurring

`SolidGcp::Recurring.load` parses recurring.yml (env-scoped like SQ: top-level env keys
or shared). Entry: `class:`/`command:`, `args:`, `queue:`, `schedule:` (parse with
`Fugit.parse` → cron string; reject non-cron `every 2s`-style if unparseable to cron).
`SchedulerSync.sync!` upserts one Cloud Scheduler job per key
(`solid-gcp-<key>`, target = push_base_url + /solid_gcp/recurring/<key>, OIDC).

## Backends

- `cloud_tasks`: real `Google::Cloud::Tasks` client behind `SolidGcp::Backends::CloudTasks`
  (constructor-injectable client for tests). Task: http_request POST, oidc_token,
  body, schedule_time.
- `local`: Thread + sleep-until, then call `Receiver.receive(envelope)` in-process
  wrapped in `Rails.application.executor.wrap`. Delays work. No GCP creds needed.
- `test`: array of pending envelopes + helpers (`SolidGcp::Testing.drain`,
  `enqueued_envelopes`).

## Error classes

`SolidGcp::Error`, `SolidGcp::NotReady`, `SolidGcp::ConfigurationError`.

## Testing requirements (gem/test, minitest)

- Adapter: enqueue/enqueue_at produce correct envelopes/schedule times; cloud_run_job
  classes route to /launch.
- Semaphore: limit honored under threads; expiry; signal caps at limit.
- Receiver: success 204; retry_on schedules new dispatch with growing waits;
  discard_on swallows; unhandled → failed_jobs row; concurrency discard/block paths;
  blocked promotion FIFO on completion; NotReady → raises through as 503 at controller.
- Concurrency DSL: static + lambda keys; refuses to load alongside Solid Queue.
- Recurring: yaml parsing, fugit conversion, /recurring endpoint enqueues.
- OIDC verifier: unit-test with stubbed verification.
- Cloud Tasks backend: task construction (stub client, assert request shape).
```
