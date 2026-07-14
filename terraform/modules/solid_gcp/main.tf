locals {
  # Cloud Tasks queue id = queue_prefix + Active Job queue name.
  # Matches SolidGcp.config.queue_prefix default "solid-gcp-".
  queue_ids = { for name in var.queue_names : name => "solid-gcp-${name}" }
}

# ---------------------------------------------------------------------------
# APIs
# ---------------------------------------------------------------------------
# Cloud Scheduler is enabled here, but individual scheduler jobs are NOT managed
# by terraform: the gem's `rake solid_gcp:scheduler:sync` upserts one job per
# recurring.yml key ("solid-gcp-<key>"). Terraform only enables the API and
# grants IAM (see README for the deploy-pipeline role the sync needs).
resource "google_project_service" "apis" {
  for_each = toset([
    "cloudtasks.googleapis.com",
    "cloudscheduler.googleapis.com",
    "run.googleapis.com",
    "iam.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Cloud Tasks queues (one per Active Job queue)
# ---------------------------------------------------------------------------
resource "google_cloud_tasks_queue" "queue" {
  for_each = local.queue_ids

  project  = var.project_id
  location = var.region
  name     = each.value

  rate_limits {
    max_dispatches_per_second = coalesce(try(var.queue_overrides[each.key].max_dispatches_per_second, null), var.default_max_dispatches_per_second)
    max_concurrent_dispatches = coalesce(try(var.queue_overrides[each.key].max_concurrent_dispatches, null), var.default_max_concurrent_dispatches)
  }

  retry_config {
    max_attempts  = coalesce(try(var.queue_overrides[each.key].max_attempts, null), var.default_max_attempts)
    min_backoff   = coalesce(try(var.queue_overrides[each.key].min_backoff, null), var.default_min_backoff)
    max_backoff   = coalesce(try(var.queue_overrides[each.key].max_backoff, null), var.default_max_backoff)
    max_doublings = coalesce(try(var.queue_overrides[each.key].max_doublings, null), var.default_max_doublings)
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Invoker service account (OIDC identity carried by pushed tasks)
# ---------------------------------------------------------------------------
# Cloud Tasks signs each push with this SA's OIDC token; the engine's
# OidcVerifier checks the token's email against it. Grant it run.invoker on the
# receiving service so the push is authorized.
resource "google_service_account" "invoker" {
  project      = var.project_id
  account_id   = "solid-gcp-invoker"
  display_name = "Solid GCP Cloud Tasks invoker (push OIDC identity)"

  depends_on = [google_project_service.apis]
}

resource "google_cloud_run_v2_service_iam_member" "invoker_runs_service" {
  count = var.service_name != "" ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = var.service_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.invoker.email}"
}

# ---------------------------------------------------------------------------
# App runtime SA — enqueuer side
# ---------------------------------------------------------------------------
# roles/cloudtasks.enqueuer, granted per-queue (least privilege) rather than
# project-wide, so the app can only create tasks on solid_gcp's own queues.
resource "google_cloud_tasks_queue_iam_member" "app_enqueuer" {
  for_each = google_cloud_tasks_queue.queue

  project  = var.project_id
  location = var.region
  name     = each.value.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${var.app_service_account_email}"
}

# roles/iam.serviceAccountUser on the invoker SA: required to create tasks whose
# OIDC token asserts the invoker SA's identity (act-as).
resource "google_service_account_iam_member" "app_uses_invoker" {
  service_account_id = google_service_account.invoker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.app_service_account_email}"
}

# Launching the Cloud Run Job (perform_via :cloud_run_job) via the Admin API
# jobs.run. The launcher passes container_overrides (SOLID_GCP_ENVELOPE env),
# which needs run.jobs.runWithOverrides. roles/run.invoker historically lacked
# that permission (see issuetracker.google.com/298810674), so we grant
# roles/run.developer scoped to the single job resource — it includes both
# run.jobs.run and run.jobs.runWithOverrides. Scoped to one job, not project-wide.
resource "google_cloud_run_v2_job_iam_member" "app_launches_job" {
  count = var.cloud_run_job_name != "" ? 1 : 0

  project  = var.project_id
  location = var.region
  name     = var.cloud_run_job_name
  role     = "roles/run.developer"
  member   = "serviceAccount:${var.app_service_account_email}"
}
