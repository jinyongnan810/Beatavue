data "google_project" "current" {
  project_id = var.project_id
  lifecycle {
    postcondition {
      condition     = self.number == "256425564793"
      error_message = "Project number must be 256425564793."
    }
  }
}

locals {
  apis = toset([
    "cloudresourcemanager.googleapis.com", "cloudbilling.googleapis.com",
    "cloudfunctions.googleapis.com", "run.googleapis.com", "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com", "firestore.googleapis.com", "secretmanager.googleapis.com",
    "cloudtasks.googleapis.com", "firebase.googleapis.com", "firebasehosting.googleapis.com",
    "firebaserules.googleapis.com", "iam.googleapis.com", "logging.googleapis.com",
    "monitoring.googleapis.com", "billingbudgets.googleapis.com", "storage.googleapis.com"
  ])
}
resource "google_project_service" "apis" {
  for_each           = local.apis
  service            = each.value
  disable_on_destroy = false
}

resource "google_service_account" "api" {
  account_id   = "beatavue-api"
  display_name = "Beatavue HTTP API"
  depends_on   = [google_project_service.apis]
}
resource "google_service_account" "worker" {
  account_id   = "beatavue-cleanup"
  display_name = "Beatavue deletion worker"
  depends_on   = [google_project_service.apis]
}
resource "google_service_account" "tasks" {
  account_id   = "beatavue-tasks"
  display_name = "Beatavue task invoker"
  depends_on   = [google_project_service.apis]
}
resource "google_service_account" "builder" {
  account_id   = "beatavue-builder"
  display_name = "Beatavue function builds"
  depends_on   = [google_project_service.apis]
}
resource "google_project_iam_member" "database" {
  project  = var.project_id
  for_each = { api = google_service_account.api.email, worker = google_service_account.worker.email }
  role     = "roles/datastore.user"
  member   = "serviceAccount:${each.value}"
}
resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.builder.email}"
}
resource "google_project_iam_member" "managed_build_source" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.builder.email}"
  condition {
    title      = "Function build source only"
    expression = "resource.type == 'storage.googleapis.com/Object' && (resource.name.startsWith('projects/_/buckets/gcf-v2-sources-${data.google_project.current.number}-${var.region}/') || resource.name.startsWith('projects/_/buckets/gcf-v2-uploads-${data.google_project.current.number}-${var.region}/') || resource.name.startsWith('projects/_/buckets/run-sources-${var.project_id}-${var.region}/'))"
  }
}
resource "google_storage_bucket" "source" {
  name                        = "${var.project_id}-function-source"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
}
resource "google_storage_bucket_iam_member" "build_source" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.builder.email}"
}
resource "google_artifact_registry_repository" "functions" {
  location      = var.region
  repository_id = "beatavue-functions"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}
resource "google_artifact_registry_repository_iam_member" "builder" {
  location   = var.region
  repository = google_artifact_registry_repository.functions.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.builder.email}"
}
resource "google_secret_manager_secret" "upload" {
  secret_id = "beatavue-upload-token"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}
resource "google_secret_manager_secret_iam_member" "upload" {
  secret_id = google_secret_manager_secret.upload.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_firestore_database" "default" {
  count                   = var.manage_firestore ? 1 : 0
  name                    = "(default)"
  location_id             = var.region
  type                    = "FIRESTORE_NATIVE"
  deletion_policy         = "ABANDON"
  delete_protection_state = "DELETE_PROTECTION_ENABLED"
  depends_on              = [google_project_service.apis]
}
resource "google_firestore_index" "samples" {
  database    = "(default)"
  collection  = "samples"
  query_scope = "COLLECTION"
  fields {
    field_path = "deleted"
    order      = "ASCENDING"
  }
  fields {
    field_path = "metric"
    order      = "ASCENDING"
  }
  fields {
    field_path = "start"
    order      = "ASCENDING"
  }
  depends_on = [google_firestore_database.default]
}
resource "google_firebaserules_ruleset" "firestore" {
  source {
    files {
      name    = "firestore.rules"
      content = file("${path.module}/firestore.rules")
    }
  }
  depends_on = [google_project_service.apis, google_firestore_database.default]
}
resource "google_firebaserules_release" "firestore" {
  name         = "cloud.firestore"
  ruleset_name = google_firebaserules_ruleset.firestore.name
}

resource "google_cloud_tasks_queue" "cleanup" {
  name     = "beatavue-cleanup"
  location = var.region
  rate_limits {
    max_dispatches_per_second = 1
    max_concurrent_dispatches = 1
  }
  retry_config {
    max_attempts       = -1
    max_retry_duration = "0s"
    min_backoff        = "10s"
    max_backoff        = "300s"
    max_doublings      = 5
  }
  depends_on = [google_project_service.apis]
}
resource "google_cloud_tasks_queue_iam_member" "enqueue" {
  name     = google_cloud_tasks_queue.cleanup.name
  location = var.region
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${google_service_account.api.email}"
}
resource "google_service_account_iam_member" "task_identity" {
  service_account_id = google_service_account.tasks.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.api.email}"
}

resource "google_cloudfunctions2_function" "cleanup" {
  count    = var.deploy_functions ? 1 : 0
  name     = "beatavue-cleanup"
  location = var.region
  build_config {
    runtime           = "python312"
    entry_point       = "cleanup"
    service_account   = google_service_account.builder.id
    docker_repository = google_artifact_registry_repository.functions.id
    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = var.source_object
      }
    }
  }
  service_config {
    available_memory                 = "256M"
    available_cpu                    = "1"
    min_instance_count               = 0
    max_instance_count               = 1
    max_instance_request_concurrency = 1
    timeout_seconds                  = 60
    service_account_email            = google_service_account.worker.email
    environment_variables            = { GOOGLE_CLOUD_PROJECT = var.project_id }
  }
  depends_on = [google_project_service.apis, google_project_iam_member.database,
    google_project_iam_member.build_logs, google_project_iam_member.managed_build_source, google_storage_bucket_iam_member.build_source,
  google_artifact_registry_repository_iam_member.builder]
  lifecycle {
    precondition {
      condition     = var.source_object != ""
      error_message = "Upload a versioned source ZIP before deploying functions."
    }
  }
}
resource "google_cloud_run_service_iam_member" "cleanup_invoker" {
  count    = var.deploy_functions ? 1 : 0
  location = var.region
  service  = google_cloudfunctions2_function.cleanup[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.tasks.email}"
}
resource "google_cloudfunctions2_function" "api" {
  count    = var.deploy_functions ? 1 : 0
  name     = "beatavue-api"
  location = var.region
  build_config {
    runtime           = "python312"
    entry_point       = "api"
    service_account   = google_service_account.builder.id
    docker_repository = google_artifact_registry_repository.functions.id
    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = var.source_object
      }
    }
  }
  service_config {
    available_memory                 = "256M"
    available_cpu                    = "1"
    min_instance_count               = 0
    max_instance_count               = 2
    max_instance_request_concurrency = 8
    timeout_seconds                  = 55
    service_account_email            = google_service_account.api.email
    environment_variables = {
      GOOGLE_CLOUD_PROJECT = var.project_id
      REGION               = var.region
      CLEANUP_URL          = google_cloudfunctions2_function.cleanup[0].service_config[0].uri
      TASK_SERVICE_ACCOUNT = google_service_account.tasks.email
    }
    secret_environment_variables {
      key        = "UPLOAD_TOKEN"
      project_id = var.project_id
      secret     = google_secret_manager_secret.upload.secret_id
      version    = var.upload_token_version
    }
  }
  depends_on = [google_project_service.apis, google_secret_manager_secret_iam_member.upload,
    google_project_iam_member.database, google_project_iam_member.build_logs, google_project_iam_member.managed_build_source,
    google_storage_bucket_iam_member.build_source, google_artifact_registry_repository_iam_member.builder,
  google_cloud_run_service_iam_member.cleanup_invoker, google_service_account_iam_member.task_identity]
}
resource "google_cloud_run_service_iam_member" "public_api" {
  count    = var.deploy_functions ? 1 : 0
  location = var.region
  service  = google_cloudfunctions2_function.api[0].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_billing_budget" "demo" {
  count           = var.billing_account == "" ? 0 : 1
  billing_account = var.billing_account
  display_name    = "Beatavue demo monthly budget"
  budget_filter { projects = ["projects/${data.google_project.current.number}"] }
  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }
  threshold_rules { threshold_percent = 0.5 }
  threshold_rules { threshold_percent = 0.9 }
  threshold_rules { threshold_percent = 1.0 }
}

resource "google_monitoring_alert_policy" "errors" {
  count        = var.deploy_functions ? 1 : 0
  display_name = "Beatavue API server errors"
  combiner     = "OR"
  conditions {
    display_name = "HTTP 5xx in API or cleanup worker"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\" AND (resource.label.service_name = \"beatavue-api\" OR resource.label.service_name = \"beatavue-cleanup\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }
  depends_on = [google_project_service.apis]
}
