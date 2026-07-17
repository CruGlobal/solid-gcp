module "solid_gcp" {
  # TODO: pin to the release tag once cru-terraform-modules PR #685 merges and
  # release-please tags it (v40.2.0 or later).
  source = "git@github.com:CruGlobal/cru-terraform-modules.git//applications/solid-gcp?ref=main"

  providers = {
    google      = google
    google-beta = google-beta
  }

  project_id                = var.project_id
  region                    = var.region
  service_name              = var.service_name
  push_base_url             = var.push_base_url
  app_service_account_email = var.app_service_account_email
  cloud_run_job_name        = var.cloud_run_job_name

  # Cable component (Firestore/Firebase).
  enable_cable       = true
  firestore_location = var.firestore_location

  # queue_names defaults to ["default", "ingest", "mailers"].

  # Ingest-storm containment (FD-315): throttle the ingest queue.
  queue_overrides = {
    ingest = {
      max_dispatches_per_second = 5
      max_concurrent_dispatches = 3
    }
  }
}
