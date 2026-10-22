# Putting the website live on prod

Prod is `coordinated-dodo-120` (Sydney). Its HTTP actions are already on `https://poddle.mikecann.app`, so the website goes live there once the backend is deployed and the site is uploaded. Run everything from the repo root with this branch checked out. Commands with `--prod` (and `npx convex deploy`) hit prod; nothing else here does.

Tested on dev (`striped-turtle-260`) on 22 Oct 2026, against the prod snapshot: the pages, link previews, the private-feed 404, `/me` with Mike's Up Next and shows, and opening links in the app on the simulator.

## 0. Before you start

- The accounts rollout (`docs/runbooks/accounts-prod.md`) must be done first: this branch builds on it, and `/me` needs real Apple and Google keys on prod (with placeholders, the pages work but signing in on the web fails).
- Back up: Dashboard > prod > Backups > Backup now.

## 1. Env

```bash
npx convex env set PODDLE_SITE_URL https://poddle.mikecann.app --prod
npx convex env list --prod | awk -F= '/^[A-Z_][A-Z0-9_]*=/{print $1}'   # names only
```

`PODDLE_SITE_URL` makes link previews point at `poddle.mikecann.app` and lets web sign-in come back there. Check there's still **no** `PODDLE_TEST_SIGNIN`.

Nothing changes with Apple or Google: their return URLs stay on `coordinated-dodo-120.ap-southeast-2.convex.site/oauth/...`, which then sends people back to the website page they started on.

## 2. Deploy the backend

```bash
npm run check
npx convex deploy
```

It installs the `staticHosting` component and adds `share:episode`, `share:show`, `sessions:recent` and the `/e/*`, `/s/*` routes. No schema changes or migrations. Until step 3, `/` shows static hosting's "Almost there!" page and `/e/*`, `/s/*` serve a bare page that still has the right link-preview tags.

## 3. Upload the site

```bash
npm run web:upload:prod
```

It builds `web/` with prod's `VITE_CONVEX_URL` (no test sign-in form) and uploads `web/dist`. Expect "Upload complete!".

## 4. Checks

```bash
S=https://poddle.mikecann.app
curl -sI $S/.well-known/apple-app-site-association | head -5        # 200, content-type: application/json, no redirect
curl -s  $S/.well-known/apple-app-site-association                  # applinks for /e/* and /s/*
curl -s -o /dev/null -w "%{http_code}\n" $S/                       # 200
curl -s -o /dev/null -w "%{http_code}\n" $S/me                     # 200
curl -s $S/e/jx73jjafkfqxydd8pahgzvx6yd8gph5z | grep -E 'og:(title|image|url)'   # a Syntax episode; og:url on poddle.mikecann.app
curl -s -o /dev/null -w "%{http_code}\n" $S/e/jx76wncq0k1n0zs7y5pm0mvcg58gpdm8    # the Patreon (private) episode: 404
```

The two episode IDs are from the prod snapshot on dev, so they should be the same on prod; if not, take any episode ID from the app (share an episode) and one from The AI Daily Brief (Ad Free).

In a browser (phone and desktop):

1. `https://poddle.mikecann.app/e/<id>?t=120` shows the episode, "Starts at 2:00", and plays from there. A timestamp in the show notes seeks.
2. Its "More from this show" link opens `/s/<id>`, with the feed URL to copy.
3. `/me`: Sign in with Apple or Google as `mike.cann@gmail.com`. Expect "Hey Mike", his Up Next (the first one marked Playing), recently listened, his shows and the week and year stats. Sign out works.
4. Paste an episode link into Slack or iMessage and check the preview (title, artwork, description). Slack and X cache previews, so use a link you haven't pasted before (adding `?t=1` makes a new one).

Apple's CDN fetches the association file within a day or so: `curl -s https://app-site-association.cdn-apple.com/a/v1/poddle.mikecann.app` should show the `applinks` block once it has.

## 5. Install the new app

```bash
scripts/install-phone.sh
```

Release now has `applinks:poddle.mikecann.app` (and `webcredentials:poddle.mikecann.app`) in place of the `coordinated-dodo-120` site. The script signs with the App Store Connect API key, so the profile picks up the change automatically. On the phone:

1. Long-press an episode > Share: the link is `https://poddle.mikecann.app/e/<id>`. A show page's share button gives `/s/<id>`. Private shows have no share button.
2. Send yourself one in Messages and tap it: Poddle opens on that episode (or show). With `?t=754` the play button says "Play from 12:34".
3. On the website, "Open in Poddle" opens the app too (it uses `poddle://`, because iOS doesn't open universal links from a page on the same site).

If a tapped link opens Safari instead, Apple's CDN hasn't picked up the file yet (see above), or the link was opened from Safari on the site itself, which iOS always keeps in Safari.

## Rollback

`npx convex deploy` the previous commit: the routes go back to what they were (the site and its `/e`, `/s` pages disappear; auth and the app are unaffected). Optionally `npx convex env remove PODDLE_SITE_URL --prod`. The uploaded files stay in the component's storage, harmlessly, until the next upload replaces them.
