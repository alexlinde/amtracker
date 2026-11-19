# amtracker-push

Cloud Run service that sends APNs Live Activity pushes for tracked Amtrak trips.
Contract: `../docs/live-activity-contract.md` (HTTP API, payloads, Firestore schema).

- `POST /trips`, `DELETE /trips/{activityId}` (Bearer `APP_SHARED_SECRET`)
- `POST /tick` (header `X-Tick-Secret`), called every minute by Cloud Scheduler
- `GET /health`

Each tick: fetch each distinct train number once from Amtraker, find the trip's locked `trainID`,
compute the ContentState, push only if it changed (or 15 min heartbeat). A trip ends (APNs `end`,
dismissal in 15 min, doc deleted) when the target stop has been departed (or arrived at the terminus)
for 10 min, the trip is over 12 h old, or the run is missing from the feed. Failed Amtraker fetches skip
the trip for that tick.

## Develop

    npm ci
    npm run build
    npm test
    npm run dryrun -- 6 TRU            # live data, nothing sent
    npm run dryrun -- 6 TRU --file test/fixtures/train6.json
    npm run dryrun -- 6 TRU --end      # show the `end` payload

Env (Cloud Run injects the secrets): `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APP_SHARED_SECRET`,
`TICK_SECRET`, `GOOGLE_CLOUD_PROJECT`, optional `APP_BUNDLE_ID` (default `com.somefamilies.amtracker`), `PORT`.
Firestore uses Application Default Credentials (or the emulator via `FIRESTORE_EMULATOR_HOST`).

## APNs key

1. developer.apple.com -> Certificates, Identifiers & Profiles -> Keys -> (+).
2. Name it, tick **Apple Push Notifications service (APNs)**, Continue, Register.
3. Download the `.p8` (one time only). Note the **Key ID** (10 chars, shown on the key page and in the file name).
4. Note your **Team ID** (Membership details page, top right of the portal).

One key works for both sandbox (`development`) and production.

## Deploy

    ./deploy.sh --apns-key ~/Downloads/AuthKey_ABC123DEFG.p8 --key-id ABC123DEFG --team-id TEAM123456

`PROJECT` (default `angular-axe-515221`) and `REGION` (default `us-west1`) are env-overridable. The script is
idempotent: secrets get a new version only if none exists (or with `--update-secrets`); the two shared secrets
are generated randomly on first run and never rotated implicitly. It prints the service URL and
`APP_SHARED_SECRET` for the iOS config. `./deploy.sh --status` shows URL, scheduler state and trip count.

## Logs

    gcloud run services logs read amtracker-push --region us-west1 --project angular-axe-515221 --limit 100
    gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="amtracker-push"' --limit 50

Scheduler: `gcloud scheduler jobs describe amtracker-tick --location us-west1`.
