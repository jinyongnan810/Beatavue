output "project_number" { value = data.google_project.current.number }
output "source_bucket" { value = google_storage_bucket.source.name }
output "api_url" { value = try(google_cloudfunctions2_function.api[0].service_config[0].uri, null) }
output "upload_secret" { value = google_secret_manager_secret.upload.secret_id }
