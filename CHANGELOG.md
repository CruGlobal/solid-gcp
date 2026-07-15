# Changelog

Versions cover the whole repo: the `solid_gcp` gem and the Terraform module
share one tag (`vX.Y.Z`), so a Gemfile `tag:` pin and a Terraform `?ref=` pin
name the same tested combination.

## [Unreleased]

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
