variable "project_id" {
  type        = string
  default     = "cru-mattdrees-sandbox-poc"
  description = "Matt's sandbox project."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Sandbox region."
}

variable "service_name" {
  type        = string
  default     = "solid-gcp-dummy"
  description = "Placeholder Cloud Run service receiving pushes in the sandbox."
}

variable "push_base_url" {
  type        = string
  default     = "https://solid-gcp-dummy-PLACEHOLDER.us-central1.run.app"
  description = "Placeholder public base URL; override once the dummy service is deployed."
}

variable "app_service_account_email" {
  type        = string
  default     = "178891842216-compute@developer.gserviceaccount.com"
  description = <<-EOT
    Sandbox app runtime SA (default Compute Engine SA of the sandbox project).
    Override with a dedicated SA before real use.
  EOT
}

variable "cloud_run_job_name" {
  type        = string
  default     = "solid-gcp-dummy-import"
  description = "Placeholder Cloud Run Job (jira-import-style runner) for cloud_run_job mode."
}
