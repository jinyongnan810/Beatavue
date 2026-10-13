terraform {
  required_version = ">= 1.6"
  backend "gcs" {}
  required_providers {
    google-beta = { source = "hashicorp/google-beta", version = "~> 7.0" }
    google      = { source = "hashicorp/google", version = "~> 7.0" }
  }
}

provider "google" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  billing_project       = var.project_id
  user_project_override = true
}
