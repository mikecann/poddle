# Releasing Poddle to the App Store

Every step from here to "Submitted for review" for v1 (decisions.md, "App Store": free, iPhone only, worldwide, open sign-up). It goes in after the Cloud Fluff restyle, so do this from a branch that has it.

The App Store Connect app already exists: **Poddle**, Apple ID `6825613455`, bundle `com.mikecann.poddle`, primary language English (Australia). The scripts use the Admin API key `~/.config/poddle/AuthKey_7SS6J9F98P.p8` (key `7SS6J9F98P`, issuer `69a6de6f-a06e-47e3-e053-5b8c7c11a4d1`). Never print it.

Prod is `coordinated-dodo-120` (Sydney). Commands with `--prod`, and `npx convex deploy`, hit prod; nothing else here does. Run everything from the repo root.

## 0. Before you start

- `npm run check` passes, and `cd Packages/PoddleKit && swift test` passes.
- `appstore/metadata.json` has been read and okayed by Mike (subtitle, description, keywords, promotional text, age rating answers, review notes), and the review contact's phone number is in `review.contactPhone` (Mike gives it; it's a placeholder until then).
- On dev, deleting a test account works end to end (sign in with test sign-in, Profile > Delete account), and `/privacy` and `/support` look right.

## 1. Deploy the backend

```sh
npx convex deploy
```

This brings `users:deleteAccount`, the `accountDeletions` table, the hourly "resume account deletions" cron and the open sign-up switch. Check the deploy output has no schema errors.

## 2. Upload the website

```sh
npm run web:upload:prod
```

Expect "Upload complete!". Then check, signed out:

- `https://poddle.mikecann.app/privacy` and `https://poddle.mikecann.app/support` load, and the footer links to both.
- `https://poddle.mikecann.app/sample-overcast.opml` downloads (App Review uses it to try the import).

## 3. Open sign-up on prod

App Review signs up with their own Apple or Google account, so this has to be on **before** submitting.

```sh
npx convex env set PODDLE_OPEN_SIGNUP 1 --prod
npx convex env list --prod | awk -F= '/^[A-Z][A-Z0-9_]*=/{print $1}'
```

The list should have `PODDLE_OPEN_SIGNUP` and still **no** `PODDLE_TEST_SIGNIN`. The home page now says anyone can sign in. To close it again: `npx convex env remove PODDLE_OPEN_SIGNUP --prod` (people who already have accounts keep them).

## 4. Set the listing

```sh
node scripts/appstore-metadata.mjs --dry-run   # read what it would change
node scripts/appstore-metadata.mjs             # change it
node scripts/appstore-metadata.mjs --dry-run   # should say "Everything's up to date."
```

It sets the content rights declaration, categories (News, then Entertainment), the en-AU name, subtitle and privacy policy URL, the 1.0.0 version's copyright, description, keywords, promotional text, support and marketing URLs, the age rating answers, a free price, worldwide availability, and the App Review contact and notes. It leaves the phone number alone while it's a placeholder.

If it lists age rating questions as "still unanswered" (Apple adds new ones), answer them in App Store Connect > App Information > Age Rating, or add them to `ageRating` in `metadata.json` and run it again.

## 5. App Privacy

Click through `docs/runbooks/app-privacy-answers.md` in App Store Connect > App Privacy, then **Publish**.

## 6. Screenshots

The App Store needs the **6.9-inch iPhone** size, **1320 × 2868** (portrait). Smaller iPhone sizes are scaled from it. Take them after the restyle, from **sample data only** (never Mike's real library):

```sh
DEVICE="iPhone 17 Pro Max" OUT=/tmp/poddle-appstore-shots scripts/screenshots.sh upNext nowPlaying npSettings podcast stats yearInReview importDone library
```

`screenshots.sh` builds Debug, launches each screen with `-PoddleMock YES` (sample data) and sets the status bar to 9:41 with full battery. Check each one is 1320 × 2868 (`sips -g pixelWidth -g pixelHeight /tmp/poddle-appstore-shots/*.png`), pick 3 to 10 that tell the story (Up Next, Now Playing, the speed settings, a show, Stats, Year in Review, the Overcast import), then upload them in App Store Connect > the 1.0.0 version > Previews and Screenshots > iPhone 6.9" Display, in that order. No iPad screenshots: v1 is iPhone only.

## 7. Upload a build

```sh
scripts/appstore-upload.sh            # archive, export and validate; stops before uploading
UPLOAD=1 scripts/appstore-upload.sh   # the real thing
```

It archives Release for iOS (prod backend, iPhone only, version 1.0.0), sets the build number to the UTC time as `YYMMDDHHMM`, exports with cloud-managed App Store signing through the API key, validates with `altool`, and with `UPLOAD=1` uploads. Note the build number it prints. Processing takes 5 to 30 minutes; App Store Connect emails when it's done.

If it's the first build, App Store Connect may ask about export compliance: `ITSAppUsesNonExemptEncryption` is `NO` in `App/Info.plist` (Poddle only uses HTTPS), so it shouldn't.

## 8. Choose the build

App Store Connect > Poddle > iOS App 1.0.0 > Build > **Add Build** (the + by "Build"), pick the build number from step 7, **Done**, then **Save** at the top right.

## 9. Final checks in App Store Connect

On the 1.0.0 version page and App Information, check:

- Screenshots are there for iPhone 6.9".
- Promotional text, description, keywords, support and marketing URLs are filled in, and the version is 1.0.0 with copyright "2026 Mike Cann".
- App Review Information: sign-in required is **off**, the contact name, email and **phone** are filled in, and the notes are there.
- App Information: subtitle, categories News and Entertainment, privacy policy URL, age rating, content rights ("contains third-party content").
- Pricing and Availability: Free, all countries and regions.
- App Privacy: published.
- Version Release: "Manually release this version" is the safe choice for a first launch.

## 10. Submit

**Add for Review** at the top right of the version page, answer anything it still asks, then **Submit for Review** (or **Submit to App Review**). The status goes to "Waiting for Review". That's it: "Submitted for review".

## Shipping an update (1.0.1 onwards)

1.0.0 went out on 27 Oct 2026. For each update after that:

1. Bump `MARKETING_VERSION` in `Poddle.xcodeproj/project.pbxproj` (all four lines, app and UI tests) and `version` in `appstore/metadata.json`, and write `whatsNew` there ("What's New in This Version", required for updates). Keep Overcast's names out of it.
2. Check the build still works against prod's backend and the other way round: prod keeps serving the old version until people update, so a Convex change the new app needs has to be deployed first, and it mustn't break the old app.
3. `node scripts/appstore-metadata.mjs --dry-run`, then without `--dry-run`. With nothing being prepared it creates the new version. App Store Connect copies the previous version's description, keywords, review details and screenshots into it, but not the promotional text, which the script fills in.
4. If `docs/runbooks/app-privacy-answers.md` changed since the last release, click the new answers into App Privacy and **Publish** before submitting. The first build with Sentry crash reporting (main from 29 Oct 2026) adds Diagnostics > Crash Data.
5. If the screens changed, retake the screenshots (step 6) and upload them with `node scripts/appstore-screenshots.mjs <pngs in order>`, which replaces the set.
6. `UPLOAD=1 scripts/appstore-upload.sh`, then `node scripts/appstore-submit.mjs <build> --submit`. If Apple refuses it with a 409, the lines above the raw error say what's missing. For 1.0.1 it was a new age rating question (`socialMedia`), answered in `metadata.json` and sent with the metadata script.
7. Once it's approved, release it (App Store Connect, or `POST /v1/appStoreVersionReleaseRequests` with the version's id).

## If it's rejected

Read the message in App Store Connect > Resolution Center. Fix it, bump nothing (the version stays 1.0.0), upload a new build with `UPLOAD=1 scripts/appstore-upload.sh` (it gets a new build number), choose it in step 8, and resubmit. Listing-only fixes just need the metadata script again and a resubmit.
