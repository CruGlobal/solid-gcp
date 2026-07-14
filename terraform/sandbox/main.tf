module "solid_gcp" {
  source = "../modules/solid_gcp"

  project_id                = var.project_id
  region                    = var.region
  service_name              = var.service_name
  push_base_url             = var.push_base_url
  app_service_account_email = var.app_service_account_email
  cloud_run_job_name        = var.cloud_run_job_name

  # queue_names defaults to ["default", "ingest", "mailers"].

  # Ingest-storm containment (FD-315): throttle the ingest queue.
  queue_overrides = {
    ingest = {
      max_dispatches_per_second = 5
      max_concurrent_dispatches = 3
    }
  }
}
