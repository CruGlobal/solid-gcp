terraform {
  required_version = ">= 1.5"

  # Local state — sandbox only, kept simple. Move to a GCS backend before any
  # shared/prod use.
  backend "local" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Cable resources in the module use google-beta.
provider "google-beta" {
  project = var.project_id
  region  = var.region
}
