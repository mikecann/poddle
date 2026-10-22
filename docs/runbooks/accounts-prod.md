# Putting accounts live on prod

Prod is `coordinated-dodo-120` (Sydney). Run everything from the repo root with this branch checked out. Commands with `--prod` hit prod; nothing else here does. Never set `PODDLE_TEST_SIGNIN` on prod.

Tested on dev (`striped-turtle-260`) against the 22 Oct prod snapshot (65,319 documents). See the counts at the bottom.

## 0. Before you start

- Back up: Dashboard > prod > Backups > Backup now (daily backups also run at 06:01 Perth). Or `npx convex export --prod --path /tmp/poddle-prod-pre-accounts.zip`.
- Note that the app on Mike's phone is the pre-accounts build. Once step 2 deploys, it can't sync (its token arg is gone) until he installs the new build (step 5). Its outbox is kept on the phone and replays after he signs in, so do steps 2 to 5 in one sitting.

## 1. Env (before deploying: the auth components won't deploy without it)

```bash
node scripts/set-auth-keys.mjs prod                       # AUTH_PRIVATE_KEY, AUTH_JWKS (skips if set)
node scripts/set-oauth-keys.mjs prod ~/Downloads/poddle-oauth.json   # real Apple + Google values
#   or, if Apple/Google aren't ready yet:
node scripts/set-oauth-keys.mjs prod --placeholders
npx convex env set PODDLE_ALLOWED_EMAILS mike.cann@gmail.com --prod
npx convex env list --prod | awk -F= '/^[A-Z_][A-Z0-9_]*=/{print $1}'   # names only
```

Check the list has `AUTH_PRIVATE_KEY`, `AUTH_JWKS`, the six `AUTH_APPLE_*`/`AUTH_GOOGLE_*`, `PODDLE_ALLOWED_EMAILS`, `PODDLE_API_TOKEN` (kept for scripts) and the five `APNS_*`, and **no** `PODDLE_TEST_SIGNIN`.

Register the prod return URLs with Apple and Google (README, "Setting up Apple and Google sign-in"). If prod's HTTP actions are moving to `poddle.mikecann.app` with `CONVEX_SITE_URL` overridden, decide that first: the callbacks and the JWT issuer follow `CONVEX_SITE_URL` (docs/api.md, "Custom domain").

## 2. Deploy

```bash
npm run check
npx convex deploy
```

The schema still allows personal rows without an owner (`vOwner` is optional), so the deploy validates against the old data. It installs the `auth`, `authApple`, `authGoogle` and `authAnonymous` components.

## 3. The migration

```bash
npx convex run migrations:report --prod > /tmp/before.json
npx convex run migrations:run --prod          # prints Mike's user id
# give it a minute (it pages through in the background), then:
npx convex run migrations:report --prod > /tmp/after.json
```

Done when every table shows `unowned: 0`, `podcasts` shows `legacy: 0`, `users.total` is 1 and `subscriptions.total` equals `podcasts.total`. If not, wait and report again; running `migrations:run` again is safe.

## 4. Checks

```bash
ID='{"subject":"<Mike'"'"'s user id from step 3>"}'
npx convex run queue:upNext --identity "$ID" --prod | head
npx convex run podcasts:list --identity "$ID" --prod | grep -c '"_id"'
npx convex run stats:summary '{"period":"all"}' --identity "$ID" --prod | head -20
npx convex run queue:upNext --prod            # must fail: "Sign in first"
```

Expect his Up Next, his subscribed shows and his all-time stats, and the unauthenticated call refused. Also check Logs for errors from the 15-minute feed poll.

## 5. Install the new app

```bash
scripts/install-phone.sh
```

It builds Release (prod), signs with the App Store Connect API key so the new associated-domains capability is provisioned automatically, and installs on Mike's phone. On the phone: Sign in with Apple or Google using `mike.cann@gmail.com` (Apple: share the real email, not "Hide my email"). He lands in his migrated account. The old app's cache and queued actions move into his account folder; queued actions replay. Then Settings shows "Mike Cann · Sign Out".

## 6. Later: make owners required

Once step 3 reports all zeros, change `export const vOwner = v.optional(v.id("users"));` to `export const vOwner = v.id("users");` in `convex/schema.ts`, run `npm run check`, and `npx convex deploy`. (Tested to typecheck. Dropping `legacyPodcastFields` from the schema goes with deleting `migrations.moveSubscriptions`, in a later cleanup.)

## Rollback

Restore the step-0 backup (Dashboard > Backups > Restore) and deploy the previous commit. The old app still has the old token in its Keychain.

## Dev rehearsal, 22 Oct 2026

| table | before total / unowned | after total / unowned |
|---|---|---|
| users | 0 | 1 |
| subscriptions | 0 | 37 |
| podcasts (legacy fields) | 37 (37 legacy) | 37 (0 legacy) |
| episodeStates | 6,967 / 6,967 | 6,968 / 0 (one new Inbox entry from the feed poll) |
| listeningSessions | 6,644 / 6,644 | 6,644 / 0 |
| libraryEvents | 6,992 / 6,992 | 6,992 / 0 |
| episodeTotals | 6,634 / 6,634 | 6,634 / 0 |
| deletions | 6,415 / 6,415 | 6,415 / 0 |
| statsShowDays | 5,445 / 5,445 | 5,445 / 0 |
| statsDays | 2,243 / 2,243 | 2,243 / 0 |
| statsShowMonths | 928 / 928 | 928 / 0 |
| statsMonths | 125 / 125 | 125 / 0 |
| podcastSettings | 33 / 33 | 33 / 0 |
| queueItems | 13 / 13 | 13 / 0 |
| globalSettings, importBatches | 1 / 1 each | 1 / 0 each |
| devices | 0 | 0 |
