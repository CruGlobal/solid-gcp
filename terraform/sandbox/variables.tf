# Per-developer values (project id, SA, URLs) come from terraform.tfvars —
# gitignored; copy terraform.tfvars.example and edit.

variable "project_id" {
  type        = string
  description = "Your sandbox GCP project id."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Sandbox region."
}

variable "service_name" {
  type        = string
  default     = "solid-gcp-dummy"
  description = "Cloud Run service receiving pushes (the deployed dummy app)."
}

variable "push_base_url" {
  type        = string
  description = "Public base URL of the deployed dummy service (https://...run.app)."
}

variable "app_service_account_email" {
  type        = string
  description = <<-EOT
    Sandbox app runtime SA (e.g. the project's default Compute Engine SA,
    <project-number>-compute@developer.gserviceaccount.com). Use a dedicated SA
    before real use.
  EOT
}

variable "cloud_run_job_name" {
  type        = string
  default     = "solid-gcp-dummy-import"
  description = "Cloud Run Job (jira-import-style runner) for cloud_run_job mode."
}

variable "firestore_location" {
  type        = string
  default     = null
  description = <<-EOT
    Firestore location for the cable database; defaults to var.region. If your
    sandbox already has a "(default)" Firestore DB in another location, set this
    to match it (immutable once created).
  EOT
}
