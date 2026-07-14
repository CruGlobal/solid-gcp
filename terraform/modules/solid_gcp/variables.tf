variable "project_id" {
  type        = string
  description = "GCP project id hosting the queues, invoker SA, and Cloud Run resources."
}

variable "region" {
  type        = string
  description = "GCP region. Used for Cloud Tasks queue location and Cloud Run resources."
}

variable "service_name" {
  type        = string
  default     = ""
  description = <<-EOT
    Name of the Cloud Run (v2) service that receives Cloud Tasks HTTP pushes at
    /solid_gcp/perform (etc.). When set, the invoker SA is granted roles/run.invoker
    on it. Leave empty to skip that binding (e.g. service managed elsewhere).
  EOT
}

variable "push_base_url" {
  type        = string
  description = <<-EOT
    Public base URL of the Cloud Run service (e.g. https://app-xxxx.run.app).
    Cloud Tasks targets push_base_url + /solid_gcp/perform; the app also uses it as
    the recurring Scheduler job target base. Surfaced as the SOLID_GCP_PUSH_BASE_URL
    output for the app config.
  EOT
}

variable "queue_names" {
  type        = list(string)
  default     = ["default", "ingest", "mailers"]
  description = <<-EOT
    Active Job queue names. Each maps 1:1 to a Cloud Tasks queue named
    "solid-gcp-<name>" (matches SolidGcp.config.queue_prefix default "solid-gcp-").
  EOT
}

variable "default_max_dispatches_per_second" {
  type        = number
  default     = 100
  description = "Default Cloud Tasks rate_limits.max_dispatches_per_second per queue."
}

variable "default_max_concurrent_dispatches" {
  type        = number
  default     = 100
  description = "Default Cloud Tasks rate_limits.max_concurrent_dispatches per queue."
}

variable "default_max_attempts" {
  type        = number
  default     = 100
  description = <<-EOT
    Default Cloud Tasks retry_config.max_attempts per queue. NOT unlimited by design:
    Active Job owns app-level retries (retry_on re-enqueues new tasks), so Cloud Tasks
    retries only exist to absorb infra-not-ready 503s (Neon cold connect). A finite
    cap prevents a permanently-broken target from retrying forever. Use -1 for
    unlimited only if you deliberately want that.
  EOT
}

variable "default_min_backoff" {
  type        = string
  default     = "5s"
  description = "Default Cloud Tasks retry_config.min_backoff per queue (duration string)."
}

variable "default_max_backoff" {
  type        = string
  default     = "300s"
  description = "Default Cloud Tasks retry_config.max_backoff per queue (duration string)."
}

variable "default_max_doublings" {
  type        = number
  default     = 5
  description = "Default Cloud Tasks retry_config.max_doublings per queue."
}

variable "queue_overrides" {
  type = map(object({
    max_dispatches_per_second = optional(number)
    max_concurrent_dispatches = optional(number)
    max_attempts              = optional(number)
    min_backoff               = optional(string)
    max_backoff               = optional(string)
    max_doublings             = optional(number)
  }))
  default     = {}
  description = <<-EOT
    Per-queue overrides keyed by Active Job queue name (NOT the "solid-gcp-" prefixed
    id). Any unset field falls back to the corresponding default_* variable.

    The "ingest" queue is where ingest-storm containment lives (Flightdeck FD-315):
    tighten max_dispatches_per_second / max_concurrent_dispatches here to throttle
    downstream load. Example:
      queue_overrides = {
        ingest = { max_dispatches_per_second = 5, max_concurrent_dispatches = 3 }
      }
  EOT
}

variable "cloud_run_job_name" {
  type        = string
  default     = ""
  description = <<-EOT
    Optional Cloud Run (v2) Job name that runs jobs declaring
    `perform_via :cloud_run_job` (e.g. the jira import runner). When set, the app
    runtime SA is granted permission to launch it (jobs.run with overrides). Leave
    empty if no cloud_run_job mode is used.
  EOT
}

variable "app_service_account_email" {
  type        = string
  description = <<-EOT
    Runtime service account email of the Cloud Run service (the enqueuer side).
    It creates Cloud Tasks tasks bearing the invoker SA's OIDC identity and launches
    the Cloud Run Job, so it receives: cloudtasks.enqueuer on each queue,
    iam.serviceAccountUser on the invoker SA, and (if cloud_run_job_name set)
    run.developer on the job. When enable_cable is set it also gets datastore.user
    and serviceAccountTokenCreator-on-itself (see cable.tf).
  EOT
}

# ---------------------------------------------------------------------------
# Cable component (SolidGcp::Cable) — see cable.tf
# ---------------------------------------------------------------------------
variable "enable_cable" {
  type        = bool
  default     = false
  description = <<-EOT
    Provision the Cable component infra (Firestore realtime streams + Firebase
    Auth custom tokens): Firestore "(default)" database + TTL policy, Firebase
    project add-on + web app, Identity Platform config, Firestore security rules,
    and runtime-SA IAM. Requires a configured google-beta provider to be passed
    to the module. Leave false for a queue-only deployment.
  EOT
}

variable "firestore_location" {
  type        = string
  default     = null
  description = <<-EOT
    Firestore database location id. Defaults to var.region when null. NOTE:
    Firestore multi-region ids (e.g. "nam5", "eur3") differ from Cloud Run region
    names; single-region ids like "us-central1" are valid and fine for the sandbox.
    Immutable once the database exists. Only used when enable_cable is true.
  EOT
}

variable "cable_collection" {
  type        = string
  default     = "solid_gcp_streams"
  description = <<-EOT
    Firestore collection holding one doc per stream. Must match
    SolidGcp.config.cable.collection and the shipped Stimulus controller's doc
    path. Parameterizes the TTL field policy and the security rules. Only used
    when enable_cable is true.
  EOT
}

variable "firebase_web_app_display_name" {
  type        = string
  default     = "Solid GCP Cable"
  description = "Display name for the Firebase web app. Only used when enable_cable is true."
}
