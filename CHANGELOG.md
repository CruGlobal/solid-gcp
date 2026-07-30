# Changelog

Versions cover the `solid_gcp` gem (repo tags `vX.Y.Z`). The companion Terraform
module lives in [cru-terraform-modules](https://github.com/CruGlobal/cru-terraform-modules/tree/main/applications/solid-gcp)
and versions independently — entries here call out when a gem release needs a
module update. (Through v0.2.0 the module lived in this repo and shared the gem's
tag.)

## [Unreleased]

## [0.5.0] - 2026-07-30

- Cable: the Stimulus controller is served by the engine (importmap pin) instead
  of being copied into apps, and `cable_install` now just registers it in
  `app/javascript/controllers/index.js`. There were three diverging copies of that
  file — the generator's was two features behind, so `cable_install` installed a
  client that subscribed to the `(default)` Firestore database (reintroducing the
  bug 0.3.0 fixed) and had no emulator support (so the documented emulator dev
  flow silently talked to real Firestore). `--vendor` copies the shipped file for
  apps that bundle JS with esbuild/webpack.
  **Upgrading:** delete any vendored `app/javascript/controllers/solid_gcp_cable_controller.js`
  and re-run `bin/rails generate solid_gcp:cable_install`.
- Cable: a listener the server hasn't answered within the new
  `config.cable.listen_timeout` (10s) is reported — `console.error` plus the
  existing `solid-gcp-cable:failed` event — and so are terminal Firestore codes
  (`not-found`, `invalid-argument`, `failed-precondition`, `unimplemented`), which
  also detach. A listen against a database that doesn't exist retries forever
  without ever erroring, so nothing else noticed: auth succeeded, the channel
  200d, the feature had simply never worked. Transient errors on a doc that has
  never gone live now get one `console.warn` rather than a hidden `console.debug`.
- Cable: cache-sourced snapshots are ignored (`metadata.fromCache`). Firestore
  serves one immediately from its local cache when it can't reach the backend, so
  the client used to announce a doc as live — `solid-gcp-cable:listening` and
  `data-solid-gcp-cable-listening` — for a listener that was dead. Both now mean
  the server answered. Refreshes are likewise only triggered by server-confirmed
  changes.
- CI: the cable client is covered end to end on every PR by a system test against
  the prebuilt Firebase emulators image (no GCP credentials), using a *named*
  Firestore database. The credential-gated live-Firestore test remains for
  release checks.

## [0.4.0] - 2026-07-30

- Recurring: `recurring.yml` is parsed with `ActiveSupport::ConfigurationFile`,
  which is what Solid Queue reads it with, so ERB and YAML anchors both work as
  they do there. Previously a plain `YAML.load_file` ignored ERB and rejected
  aliases, so the env-scoped form written idiomatically as `default: &default`
  merged into each env with `<<: *default` — i.e. a file copied straight off a
  Solid Queue app — raised `Psych::AliasesNotEnabled`.
- Recurring: an env-scoped `recurring.yml` with no section for the current env
  now raises `ConfigurationError` naming the env and the sections present.
  Previously it fell back to treating the whole file as the entry list, so every
  env name became a job key and `scheduler:sync` would create Cloud Scheduler
  jobs named `solid-gcp-production` and friends. A flat (unscoped) file is still
  read as the entry list.

## [0.3.0] - 2026-07-29

- Cable: named Firestore databases. `config.cable.database` already reached the
  server's REST calls, but the browser was pinned to `(default)` — the client
  now receives a `databaseId` key and passes it to `getFirestore`. Emitted only
  when the database is not `(default)`, so existing apps see no change. Pair
  with `firestore_database_id` in the Terraform module; a named database lets
  `deletion_policy = "DELETE"` drop just the cable's data instead of every
  Firestore collection in the project.
- Terraform module moved to cru-terraform-modules (`applications/solid-gcp`),
  per devops convention; `terraform/` here retains only the sandbox
  instantiation, now parameterized per developer via `terraform.tfvars`.

## [0.2.0] - 2026-07-15

- Local recurring ticker: in `:local` mode a server process ticks the current
  env's `recurring.yml` entries in-process (dev stand-in for Cloud Scheduler),
  through the same enqueue path as `/recurring/:key`. Consoles/rake don't tick.
- Cable: Firebase emulator support. With `FIRESTORE_EMULATOR_HOST` /
  `FIREBASE_AUTH_EMULATOR_HOST` set (or the matching config attrs), the whole
  flow runs against the local emulators with no GCP credentials — project
  defaults to `demo-solid-gcp`.
- Prebuilt Firestore + Auth emulators image
  (`ghcr.io/cruglobal/solid-gcp-firebase-emulators`, tag tracks firebase-tools
  version): consumers run the Cable dev backend via `docker run` instead of
  installing a JRE + firebase-tools; apps mount their own firebase.json /
  firestore.rules for rules parity. Built in `emulator-image/`.

## [0.1.0] - 2026-07-14

Initial release.

- Active Job adapter: Cloud Tasks HTTP push delivery (OIDC-signed) to a
  mounted Rails engine — no polling processes, true scale-to-zero.
- `limits_concurrency` DSL on Postgres semaphores + blocked-jobs table, with
  self-scheduled sweep (no cron).
- `perform_via :cloud_run_job` — long jobs as Cloud Run Job executions.
- Recurring jobs: `config/recurring.yml` synced to Cloud Scheduler.
- Failed-job recording + retry API.
- `SolidGcp::Cable`: Firestore-backed realtime refresh (touch/subscribe) with
  Firebase custom-token auth; Stimulus client with backoff, re-auth, and
  online/visibility resume.
- `:local` and `:test` modes; install + cable-install generators with
  build-safe (tolerant-ENV) config templates.
- `ActiveSupport::Notifications` events (`*.solid_gcp`), enqueue-time payload
  size limit, HTTP resilience (timeouts + retry) on REST paths.
- Terraform module: Cloud Tasks queues, service accounts + IAM, Cloud
  Scheduler, Cloud Run service + Job, Firestore/Firebase resources.

[Unreleased]: https://github.com/CruGlobal/solid-gcp/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/CruGlobal/solid-gcp/releases/tag/v0.1.0
