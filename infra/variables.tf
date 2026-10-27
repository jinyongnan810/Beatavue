variable "project_id" {
  type    = string
  default = "beatavue"
  validation {
    condition     = var.project_id == "beatavue"
    error_message = "This deployment targets the existing beatavue project."
  }
}
variable "region" {
  type    = string
  default = "asia-northeast1"
}
variable "app_check_app_id" {
  description = "Firebase web app ID registered with App Check (1:256425564793:web:...). Required when deploying the API."
  type        = string
  default     = ""
  validation {
    condition     = var.app_check_app_id == "" || can(regex("^1:256425564793:web:[a-f0-9]+$", var.app_check_app_id))
    error_message = "Use the Firebase web app ID belonging to beatavue."
  }
}
variable "deploy_functions" {
  type    = bool
  default = false
}
variable "source_object" {
  description = "Immutable ZIP uploaded by scripts/package-api.py; never contains secrets or health data."
  type        = string
  default     = ""
}
variable "upload_token_version" {
  description = "Numeric Secret Manager version, provisioned outside Terraform."
  type        = string
  default     = "1"
  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.upload_token_version))
    error_message = "Pin a numeric secret version."
  }
}
variable "budget_amount" {
  type    = number
  default = 10
}
variable "billing_account" {
  description = "Optional billing account ID for a budget; billing must already be enabled on the project."
  type        = string
  default     = ""
}
variable "manage_firestore" {
  description = "Import an existing (default) database before apply; never create a second one."
  type        = bool
  default     = true
}
