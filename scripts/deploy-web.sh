#!/bin/sh
set -eu
: "${VITE_FIREBASE_API_KEY:?Set the Firebase web API key}"
: "${VITE_FIREBASE_APP_ID:?Set the Firebase web app ID}"
: "${VITE_RECAPTCHA_ENTERPRISE_SITE_KEY:?Set the reCAPTCHA Enterprise site key}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT/web"
npm ci
npm run build
cd "$ROOT"
firebase deploy --only hosting --project beatavue
