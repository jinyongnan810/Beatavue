# Public API protection

Public GET requests to `/v1/sync-status`, `/v1/samples`, `/v1/summaries`, and
`/v1/live` require `X-Firebase-AppCheck`. The backend verifies the signature,
expiry, numeric project audience and exact issuer, and the registered web app ID.
Missing or invalid tokens return 401 before any Firestore or RTDB access.
Missing server configuration or verification infrastructure failures fail closed.
OPTIONS preflights do not require attestation or touch the database.

Browser CORS permits only `https://beatavue.web.app`, GET, and the App Check
header. Foreign origins are rejected. Same-origin GETs can omit Origin but still
require App Check. CORS is browser isolation, not authentication. The live stream
uses fetch so tokens travel in headers, never URLs. Hosting's CSP permits the
required reCAPTCHA and App Check services.

Owner uploads, live updates, and deletion continue to require the existing
UPLOAD_TOKEN Bearer credential. The iOS uploader needs no App Check migration.
Never put that owner credential in a VITE variable or browser code.

## Shared admission limits

After verification, a Firestore transaction admits at most 120 public requests
per minute per App Check token, two live streams per token, and ten live streams
across the deployment. Rejections return 429 with Retry-After, also on the direct
Cloud Run URL. The client backs off on failures and honors Retry-After.

Streams release their reservations on completion/disconnect; a 55-second lease
recovers reservations after crashes. Streams end after 40 seconds. All instances
share the limits. Client documents contain only a SHA-256 token digest, counters,
leases, and an expiry; Terraform enables TTL cleanup after 24 hours. Admission
adds Firestore reads/writes, including stream reservation and release operations.

These are per-token limits, not per-person limits: token rotation creates a new
bucket. No client-supplied IP headers are trusted. The existing global history
budget (60 requests / 100,000 reserved sample reads per 12 hours) remains in force.
Setting `api_limits/public.rateLimited` to false disables only that existing
history budget; it does not bypass App Check or these admission limits.

App Check reduces automated abuse but is not user authorization or replay
prevention. A valid token can be reused until expiry. Anyone who can view the
public dashboard can copy the published data. Use authenticated users and
server-side authorization if the data must become private.

## Configure before deploying

1. Register a Firebase **web app** in project `beatavue`. Copy its web API key
   and app ID (`1:256425564793:web:...`).
2. Create a score-based reCAPTCHA Enterprise key. Enable domain validation and
   allow only `beatavue.web.app` on the production key. Register that key for the
   web app in Firebase App Check. Start with the default one-hour token TTL.
3. Set Terraform `app_check_app_id` in the ignored `infra/terraform.tfvars`, or
   export `TF_VAR_app_check_app_id`. API deployment fails if it is missing.
   Terraform provides `APP_CHECK_APP_ID` and `FIREBASE_PROJECT_NUMBER` to the API
   and enables the required services. Standard verification does not consume
   tokens and needs no replay-protection IAM role.
4. For local frontend builds, copy `web/.env.example` to `web/.env.local` and
   fill in the public identifiers. For `scripts/deploy-web.sh`, export the three
   variables `VITE_FIREBASE_API_KEY`, `VITE_FIREBASE_APP_ID`, and
   `VITE_RECAPTCHA_ENTERPRISE_SITE_KEY` in the shell. The script rejects missing
   values before building/deploying.
5. For GitHub deployment, add variables in the `gcp` environment:
   `FIREBASE_WEB_API_KEY`, `FIREBASE_WEB_APP_ID`, and
   `RECAPTCHA_ENTERPRISE_SITE_KEY`. The workflow maps these to Terraform and Vite.
6. Coordinate the web and API deployment: the old web client has no tokens and
   cannot read the protected API. Deploy the web client first, then the API;
   a short live-stream gap is expected because the old API lacks preflight support.
   The CORS-only commit can be deployed first to eliminate that preflight gap.
   This custom HTTP API enforces App Check in its code; Firebase's enforcement
   toggles for managed services do not protect it.

For local development use a Firebase-registered App Check debug token, set via
`self.FIREBASE_APPCHECK_DEBUG_TOKEN` before App Check initializes in the browser.
Keep debug tokens out of commits and production builds. CORS intentionally
rejects localhost on the production API: use Vite's same-origin `/v1` proxy to
the local API, with the backend project number and app ID configured.
Override VITE_LIVE_API_URL to `/v1/live` locally to use the proxy.

After deployment verify: dashboard history/live work; missing/invalid tokens
return 401 through both Hosting and the direct service URL; foreign-origin
preflights return 403; extra streams return 429 and recover after closing or
lease expiry; authenticated iPhone uploads continue working.

References: [custom backend verification](https://firebase.google.com/docs/app-check/custom-resource-backend),
[web integration](https://firebase.google.com/docs/app-check/web/custom-resource),
[reCAPTCHA Enterprise setup](https://firebase.google.com/docs/app-check/web/recaptcha-enterprise-provider).
