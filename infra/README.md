# GCP infrastructure — beatavue

Existing project: **beatavue**, number **256425564793**. Terraform validates both identities.
Default region: **asia-northeast1 (Tokyo)**. Do not create a new project.
The implementation has been validated locally but is **not deployed**. GCP application-default
credentials were unavailable in the implementation environment.

## 1. Authenticate and inspect existing resources

Install Terraform ≥1.6, Google Cloud CLI, Firebase CLI, Python, and Node ≥22.12.
Use short-lived user/ADC credentials locally, or Workload Identity Federation in CI;
do not create or commit service-account JSON keys.

```sh
gcloud auth login
gcloud auth application-default login
gcloud projects describe beatavue --format='value(projectNumber)'
gcloud billing projects describe beatavue
gcloud firestore databases list --project beatavue
gcloud functions list --gen2 --project beatavue
firebase projects:list
```

Verify project number 256425564793 and active billing. If the project already has a default
Firestore database, note its **immutable location**, set `region` appropriately where supported,
and import it into Terraform instead of creating another database. Inspect existing secrets,
service accounts, buckets, task queues, and indexes too; import matching resources before apply.
Do not overwrite existing Firestore rules if the project contains other applications without
reconciling their rules first. The supplied deny-all rules assume Beatavue owns this database.

## 2. Bootstrap remote state and Firebase Hosting

The private state bucket is deliberately separate from the stack it stores:

```sh
gcloud storage buckets create gs://beatavue-terraform-state \
  --project=beatavue --location=asia-northeast1 --uniform-bucket-level-access
gcloud storage buckets update gs://beatavue-terraform-state \
  --versioning --public-access-prevention
firebase projects:addfirebase beatavue
firebase hosting:sites:list --project beatavue
```

Skip creation/addfirebase if these already exist. Firebase usually supplies the default
`beatavue` Hosting site; if absent, create it with `firebase hosting:sites:create beatavue
--project beatavue`. This CLI bootstrap avoids provider gaps and is required for Hosting;
the React app needs no Firebase app registration or Authentication service.

Restrict state bucket IAM to the deployment operator/CI identity. State contains infrastructure
identifiers but must never contain token values or health records.

```sh
terraform -chdir=infra init -reconfigure -backend-config=backend.hcl.example
# If the default Firestore database exists:
terraform -chdir=infra import 'google_firestore_database.default[0]' \
  'projects/beatavue/databases/(default)'
terraform -chdir=infra plan
terraform -chdir=infra apply
```

The first apply has `deploy_functions=false`. It enables APIs and creates the database/index,
deny-all rules, service identities, source bucket, artifact repository, task queue, and empty
secret container. Allow indexes to finish building before fetching samples.
If Firestore is managed outside this stack, set `manage_firestore=false` and verify its setup.
Terraform remains authoritative for the supplied index and rules.

Optionally set `billing_account` (format `XXXXXX-XXXXXX-XXXXXX`) to create a USD 10 monthly
budget, configurable through `budget_amount`. Ordinary budget alerts are informational.
Add notification channels to the Monitoring alert policy after deployment and verify delivery;
the default policy creates an incident but has no external notification destination.

## 3. Provision the private upload token outside Terraform

Generate a high-entropy token in your password manager. Add it through Secret Manager's
console, or supply it to the CLI through stdin:

```sh
gcloud secrets versions add beatavue-upload-token --project beatavue --data-file=-
```

Paste through stdin; never include the token in command arguments, Terraform variables/state,
repository files, build logs, or React environment variables. Note the numeric version.
Keep a copy in the owner's password manager and provision it through the iPhone Settings
SecureField, which stores it in device-only Keychain.

## 4. Deploy API and dashboard

```sh
UPLOAD_TOKEN_VERSION=1 sh scripts/deploy-api.sh
sh scripts/deploy-web.sh
```

The API script packages only four application files into a content-addressed ZIP, uploads it,
then creates a saved Terraform plan and applies that plan. Google Cloud Build builds the Python
functions. The public handler allows unauthenticated invocation, enforcing its own mutation
token; the cleanup function allows invocation only by `beatavue-tasks` via Cloud Tasks OIDC.
No load balancer, API Gateway, VPC connector, or SQL instance is required.

Persist the resulting nonsecret settings in ignored `infra/terraform.tfvars`:

```hcl
deploy_functions    = true
source_object       = "api-<sha256>.zip"
upload_token_version = "1"
```

Keep these values current before later Terraform plans, otherwise the default false flag would
plan function removal. Application deployment uses the same stack, avoiding configuration drift.
The included `Deploy Scope 2` GitHub workflow runs only through `workflow_dispatch`, using
GitHub environment `gcp` and Workload Identity Federation. Configure environment variables
`GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DEPLOY_SERVICE_ACCOUNT`, and optionally
`GCP_BILLING_ACCOUNT` (keep budget configuration consistent with local applies). Restrict the
identity provider to this repository and the deployment environment; grant only the designated
GitHub identity permission to impersonate the deploy service account. Enable environment
reviewers if desired. Bootstrap these external identity settings before dispatching the job.
The deployment identity needs state/source bucket access, permission to manage the Terraform
resources (including IAM bindings), and permission to act as the API, worker, task, and builder
accounts. This is infrastructure-operator access, separate from the limited runtime identities.
The workflow uses the remote state, runs API checks, deploys the selected component(s), and
accepts only a numeric existing secret version, never a secret value. A separate validation
workflow checks API, web, and Terraform on pushes/PRs. Neither deploys automatically on push.

After Hosting succeeds, configure the iPhone base URL as `https://beatavue.web.app` (or use
the direct HTTPS API base from `terraform output api_url`). The app starts with publishing off;
enter the private token, save the connection, and explicitly confirm public publishing.

## 5. Live acceptance

Use **synthetic samples first**, then delete that generation before importing personal history.

- Verify public reads work without a token, including both metrics, pagination, overlapping
  timestamps, empty dates, and timezone/DST boundaries.
- Verify missing/invalid tokens cannot import, upload, or delete; web assets contain no token.
- Retry one batch unchanged and confirm no duplicate records; reuse its ID with changed
  values and expect 409. Delete a UUID, then retry an older addition and verify no resurrection.
- Delete the full generation while a batch is in flight; confirm old uploads are rejected, the
  public dataset is empty, task retries purge documents, and a fresh import uses a new generation.
- Confirm Firestore direct client reads/writes are denied. Verify API/worker service accounts
  have only their required IAM access, and that the cleanup URL rejects anonymous invocation.
- On physical iPhone/Watch, opt in, go offline, collect changes, relaunch, reconnect, and confirm
  eventual uploads. Verify queue and anchors survive restart, deletion propagates, pause stops
  publishing, and locked-device failures catch up after unlocking. Background delivery is not
  guaranteed while force-quit or restricted.
- Inspect Cloud Run logs for payload/token leaks; check indexes, budget/alert delivery, API
  latency, and Cloud Tasks retry health. Confirm the shared public rate limit returns 429.

## Token rotation

Add a new secret version outside Terraform and deploy with its numeric version. Update the
same dataset's iPhone Keychain token without resetting its queue or HealthKit anchors.
Cloud Run environment secrets are resolved on startup: disable/delete old API revisions that
still reference the old version and have no intended traffic, including revision-tag access.
Disable the old Secret Manager version and verify the old token is rejected through both the
Hosting URL and direct function URL. Do not log either token during verification.

## Recovery and operational limits

- A task-enqueue failure leaves ingestion disabled. Repeat the same deletion ID from iPhone
  Settings to enqueue cleanup again. Inspect failed tasks rather than reopening the generation.
- Cleanup intentionally returns 503 after a bounded work interval; Cloud Tasks retries it.
  Monitoring may show these expected retries for very large datasets.
- Generation retirement markers contain no sample data and remain to fence delayed imports.
- API responses are not CDN-cached; deletion cannot recall data already downloaded by visitors.
- Dense summary queries return 422 rather than scanning unbounded health history. The public
  rate/read allowance is shared and conservative; tune it from measured usage before scaling.
- Confirm the actual Cloud Run service names after deployment; Firebase rewrite configuration
  assumes `beatavue-api` in Tokyo. Update both infrastructure and `firebase.json` if changing region.

Custom build-account source permissions follow [Google’s build guidance](https://docs.cloud.google.com/functions/docs/building), with a conditional grant for managed function-source buckets and a separate grant for the Beatavue source bucket.
