output "invoker_service_account_email" {
  value       = module.solid_gcp.invoker_service_account_email
  description = "Set as SOLID_GCP_INVOKER_SA on the dummy app."
}

output "queue_names" {
  value = module.solid_gcp.queue_names
}

output "push_base_url" {
  value = module.solid_gcp.push_base_url
}
