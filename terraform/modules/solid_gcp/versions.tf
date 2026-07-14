terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    # Cable resources (firebase_*, identity_platform_config, firebaserules_*) are
    # google-beta only. Consumers must pass a configured google-beta provider.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0"
    }
  }
}
