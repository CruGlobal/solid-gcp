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

---

# Cable component (`SolidGcp::Cable`)

Optional module — a queue-only adopter never loads it (no-op unless `cable.mode`
set) and it adds **no gem dependencies**: all Firestore/IAM traffic goes over REST
using `googleauth` (already a dep) — no grpc/google-cloud-firestore.

## Gem layout additions

```
lib/solid_gcp/cable.rb                       # touch/touch_later API, mode switch
lib/solid_gcp/cable/stream_name.rb           # streamables → name; sign/verify
lib/solid_gcp/cable/firestore.rb             # REST commit (increment transform)
lib/solid_gcp/cable/custom_token.rb          # Firebase custom token via IAM signBlob REST
lib/solid_gcp/cable/test_sink.rb             # :test mode capture
app/jobs/solid_gcp/cable/touch_job.rb        # touch_later rides the queue component
app/controllers/solid_gcp/cable_tokens_controller.rb
app/helpers/solid_gcp/cable_helper.rb
app/javascript/solid_gcp_cable_controller.js # canonical Stimulus controller (copied)
lib/generators/solid_gcp/cable_install/...   # copies JS controller + firestore.rules
```

## Configuration (`SolidGcp.config.cable.*`)

| key | default | notes |
|---|---|---|
| `mode` | `:off` | `:firestore` \| `:test` \| `:off` (no-op) |
| `project` | `SolidGcp.config.project` | Firestore/Firebase project |
| `database` | `"(default)"` | Firestore database id |
| `collection` | `"solid_gcp_streams"` | must match rules + terraform |
| `signer_email` | nil → ADC/metadata SA | SA whose key signs custom tokens (needs self `iam.serviceAccounts.signBlob`) |
| `firebase_web_config` | `{}` | `{apiKey:, projectId:, ...}` exposed to the client helper |
| `stream_ttl` | 30.days | sets `expires_at` on stream docs (Firestore TTL policy reaps) |
| `token_ttl` | 55.minutes | custom-token exp (Firebase cap 1h) |

## Server API

- **Stream name**: streamables → each part `to_gid_param` if GlobalID-able else
  `to_param`/`to_s`, joined `":"` (mirrors turbo-rails). **Doc id** =
  `Digest::SHA256.hexdigest(stream_name)`. **Signed stream name** =
  `Rails.application.message_verifier("solid_gcp/cable").generate(stream_name)`.
- `SolidGcp::Cable.touch(*streamables)` — Firestore REST `commit` on the stream doc:
  transform `increment(v, 1)` + set `touched_at` (server timestamp) and `expires_at`
  (now + stream_ttl). Idempotent-safe; burst coalescing is the client's job.
- `SolidGcp::Cable.touch_later(*streamables)` — enqueues `TouchJob` (Active Job →
  the queue component). Flightdeck's `broadcast_refresh_later_to` swap-in.
- `:test` mode: `TestSink.touches` records stream names; `:off`: no-op.

## Token endpoint

`POST /solid_gcp/cable/token`, JSON `{signed_stream_names: [..]}` (same-origin,
CSRF-protected, session/cookies as the host app). For each name: verify signature
(401 on any failure). Mint custom token: RS256 JWT, `iss`=`sub`=signer_email,
`aud`=`https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit`,
`uid`=SHA256 of sorted doc ids (no user identity needed — authz lives in claims),
claims `{"sgs": [doc ids]}`. Signature via IAM Credentials REST `signBlob`
(runtime SA signs as itself; no key file). **Claims cap 1000 bytes** → reject >10
streams per request (422) — a page should never need more. Response
`{"token": jwt}`.

## Client (Stimulus controller, copied by generator)

- Helper `firestore_stream_from(*streamables)` →
  `<div hidden data-controller="solid-gcp-cable" data-solid-gcp-cable-signed-name-value="…" data-solid-gcp-cable-doc-value="<collection>/<doc id>">`.
  Helper `solid_gcp_cable_config_tag` → `<script type="application/json" id="solid-gcp-cable-config">`
  with firebase_web_config + token endpoint path.
- Controller behavior: on connect, register stream in a page-level module registry;
  microtask-debounced single `fetch` of the token for all registered streams → one
  `signInWithCustomToken` → one `onSnapshot` per doc. Skip the initial snapshot;
  on any subsequent snapshot, debounce 300ms, then `Turbo.session.refresh(location.href)`
  when Turbo ≥8 is present, else dispatch `solid-gcp-cable:refresh` on `document`.
  On disconnect (page nav), unsubscribe listeners. Token expiry (~1h): on
  `permission-denied`/token-expired listener error, re-fetch token and re-attach once.
- Host app owns the `firebase` JS dep (`firebase/app`, `firebase/auth`,
  `firebase/firestore` — full, not `lite`; lite lacks `onSnapshot`).

## Firestore security rules (template shipped; terraform deploys)

```
rules_version = '2';
service cloud.firestore {
  match /databases/{db}/documents {
    match /solid_gcp_streams/{stream} {
      allow get: if request.auth != null && stream in request.auth.token.sgs;
    }
  }
}
```
No client writes, no list. Doc-level `onSnapshot` requires only `get`.

## Terraform additions (same module, `enable_cable` flag, google-beta where needed)

- `google_firestore_database` (native mode, region), `google_firestore_field` TTL
  policy on `expires_at` for the streams collection.
- `google_firebase_project`, `google_firebase_web_app` (+ web-app config data source
  → outputs for `firebase_web_config`).
- `google_identity_platform_config` (enables Firebase Auth for custom tokens).
- `google_firebaserules_ruleset` + `google_firebaserules_release` (`cloud.firestore`).
- IAM on runtime SA: `roles/datastore.user` (project) +
  `roles/iam.serviceAccountTokenCreator` on **itself** (signBlob).
- APIs: firestore, firebase, identitytoolkit, firebaserules, iamcredentials.

## Dummy app demo

importmap-rails + turbo-rails + stimulus-rails; `firebase` pinned to gstatic ESM CDN.
Dashboard: `firestore_stream_from :job_runs`; `JobRun` `after_create_commit`
→ `SolidGcp::Cable.touch_later(:job_runs)` — enqueue a demo job, watch the
dashboard morph when it completes. E2e proof on sandbox.

## Testing requirements

- StreamName: streamable coercion, sign/verify round-trip, tamper → verify fails.
- Firestore REST: commit request shape (stubbed HTTP) — increment transform, TTL field.
- CustomToken: JWT header/claims shape, aud/iss/uid/sgs, signBlob payload (stubbed).
- Tokens controller: happy path, bad signature 401, >10 streams 422, CSRF enforced.
- touch/touch_later: `:test` sink capture; TouchJob enqueues via adapter.
- Cable off: everything no-ops, no constants force-loaded needing config.
