# solid_gcp — Terraform

GCP infrastructure for the `solid_gcp` Active Job backend. See `../docs/PLAN.md`
and `../docs/DESIGN.md` for the architecture. This tree provisions the pieces the
gem needs at runtime; it does **not** provision the Rails app image, the Cloud Run
service/job themselves, or individual Cloud Scheduler jobs (those are handled
elsewhere — see below).

## Module home & consumption

This module lives here (rather than in cru-terraform) because it is
contract-coupled to the `solid_gcp` gem — per the
[colocated-modules policy](https://github.com/CruGlobal/cru-terraform-modules/blob/main/docs/colocated-modules.md).
This repo's git tags equal the gem version, so `?ref=vX.Y.Z` pins gem + module
together.

- **Real instantiation** (config + state) belongs in **cru-terraform**, sourcing:
  ```hcl
  source = "git@github.com:CruGlobal/solid-gcp.git//terraform/modules/solid_gcp?ref=vX.Y.Z"
  ```
- **`sandbox/`** is a temporary, hand-applied exception for
  `cru-mattdrees-sandbox-poc` only — not managed state. It will graduate to
  cru-terraform.
- **Guardrail:** root `CODEOWNERS` routes `/terraform/` to
  `@CruGlobal/devops-engineering-team`, and the shared reusable CI workflow
  (`.github/workflows/terraform.yml`) runs fmt/validate/tflint on changes here.

## Layout

```
terraform/
  modules/solid_gcp/   reusable module (queues, invoker SA, IAM, API enablement)
  sandbox/             instantiation for Matt's sandbox (cru-mattdrees-sandbox-poc)
```

## What the module creates

- **Cloud Tasks queues** — one per Active Job queue (`queue_names`, default
  `default`, `ingest`, `mailers`), named `solid-gcp-<name>` to match the gem's
  `queue_prefix`. Each gets `rate_limits` and `retry_config` (defaults:
  max_attempts 100, min_backoff 5s, max_backoff 300s, max_doublings 5), overridable
  per queue via `queue_overrides`. **Ingest-storm containment** (Flightdeck FD-315)
  lives on the `ingest` queue — tighten its dispatch limits there.
- **Invoker service account** (`solid-gcp-invoker`) — the identity in the OIDC
  tokens Cloud Tasks attaches to each push. Granted `roles/run.invoker` on the
  receiving Cloud Run service (only when `service_name` is set). The engine's OIDC
  verifier checks the incoming token's email against this SA.
- **App runtime SA IAM** (the enqueuer side):
  - `roles/cloudtasks.enqueuer` — granted **per queue** (least privilege), so the
    app can only enqueue on solid_gcp's queues.
  - `roles/iam.serviceAccountUser` on the invoker SA — required to create tasks that
    carry the invoker SA's OIDC identity (act-as).
  - `roles/run.developer` on the Cloud Run **Job** (only when `cloud_run_job_name`
    is set) — for launching `perform_via :cloud_run_job` executions. See IAM note
    below.
- **API enablement** — `cloudtasks`, `cloudscheduler`, `run`, `iam`.

### IAM role choice for launching the Cloud Run Job

The launcher calls the Cloud Run Admin API `jobs.run` **with container overrides**
(passing `SOLID_GCP_ENVELOPE` as an env var), which requires the
`run.jobs.runWithOverrides` permission. `roles/run.invoker` historically did **not**
include that permission (Google issue tracker 298810674), so the module grants
`roles/run.developer` scoped to the single job resource — it includes both
`run.jobs.run` and `run.jobs.runWithOverrides`. The binding is scoped to that one
job (via `google_cloud_run_v2_job_iam_member`), not project-wide.

## Consumer app configuration

The Rails app (dummy app, later Flightdeck) needs these env vars, mapping to
`SolidGcp.config`:

| Env var | Source | Notes |
|---|---|---|
| `SOLID_GCP_PROJECT` | `project_id` | GCP project id |
| `SOLID_GCP_LOCATION` | `region` | queue/scheduler/job location |
| `SOLID_GCP_PUSH_BASE_URL` | module output `push_base_url` | public base URL of the Cloud Run service; Cloud Tasks target + OIDC audience |
| `SOLID_GCP_INVOKER_SA` | module output `invoker_service_account_email` | OIDC identity set on tasks and verified on receipt |

The app must **run as** `app_service_account_email` (the SA this module grants
enqueuer / serviceAccountUser / run.developer to).

## Deploy pipeline (scheduler sync)

Terraform intentionally does **not** manage individual Cloud Scheduler jobs. The gem
owns them: `rake solid_gcp:scheduler:sync` reads `config/recurring.yml` and idempotently
upserts one Cloud Scheduler job per key (`solid-gcp-<key>`, target
`push_base_url + /solid_gcp/recurring/<key>`, OIDC as the invoker SA).

Whatever identity runs that sync (the deploy pipeline / release job — **not** the app
runtime SA) needs, in this project:

- `roles/cloudscheduler.admin` — create/update/delete scheduler jobs.
- `roles/iam.serviceAccountUser` on the invoker SA — so scheduler jobs can be
  configured to push as the invoker SA's OIDC identity.

These are deliberately kept off the app runtime SA (it never touches Scheduler at
runtime).

## Usage

```hcl
module "solid_gcp" {
  source = "./modules/solid_gcp"

  project_id                = "my-project"
  region                    = "us-central1"
  service_name              = "my-app"                 # Cloud Run service receiving pushes
  push_base_url             = "https://my-app-xxxx.run.app"
  app_service_account_email = "my-app@my-project.iam.gserviceaccount.com"
  cloud_run_job_name        = "my-app-import"          # optional
  # queue_names defaults to ["default", "ingest", "mailers"]

  queue_overrides = {
    ingest = { max_dispatches_per_second = 5, max_concurrent_dispatches = 3 }
  }
}
```

## Validate

No apply is performed here. To format and validate:

```sh
terraform fmt -recursive
cd sandbox && terraform init -backend=false && terraform validate
cd ../modules/solid_gcp && terraform init -backend=false && terraform validate
```

(`tofu` works as a drop-in for `terraform` in the commands above.)
