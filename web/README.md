# Public dashboard

React, TypeScript, Vite, and Luxon. No Firebase SDK, sign-in, mutation controls, or upload token.
Every API request uses a same-origin `/v1` route. Luxon computes day/week/month boundaries in
the selected timezone, including daylight-saving transitions. Weeks begin Monday.

```sh
cd web
npm ci
npm run dev
npm run build
```

The development server proxies `/v1` to the local API on port 8080. Start it with the Firestore
emulator as described in `api/README.md`. Without a running API the dashboard shows an error
with a retry action; it does not invent health measurements.

Day charts show actual samples with no connecting lines; week/month charts show labeled
daily sample-average points. Points can be inspected by mouse, touch, or keyboard focus.
Overlapping samples are retained. The dashboard refreshes every two minutes while visible;
manual refresh is available. Dense summaries require a shorter selection (HTTP 422).

Deployment uses the root `firebase.json`: `/v1/**` rewrites to the `beatavue-api` Cloud Run
service in Tokyo, before the SPA fallback. The public Hosting site is `beatavue` in the existing
project. See `infra/README.md` for setup and verification.
