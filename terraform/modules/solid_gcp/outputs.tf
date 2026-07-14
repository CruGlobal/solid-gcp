output "invoker_service_account_email" {
  value       = google_service_account.invoker.email
  description = "Email of the invoker SA. Set as SOLID_GCP_INVOKER_SA on the app."
}

output "queue_ids" {
  value       = { for name, queue in google_cloud_tasks_queue.queue : name => queue.id }
  description = "Map of Active Job queue name -> full Cloud Tasks queue resource id."
}

output "queue_names" {
  value       = { for name, queue in google_cloud_tasks_queue.queue : name => queue.name }
  description = "Map of Active Job queue name -> Cloud Tasks queue short name (solid-gcp-<name>)."
}

output "push_base_url" {
  value       = var.push_base_url
  description = "Echoed back for convenience; set as SOLID_GCP_PUSH_BASE_URL on the app."
}
