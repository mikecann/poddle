# App Privacy answers (App Store Connect)

The App Privacy questionnaire can't be set through the API, so click these in by hand: App Store Connect > Apps > Poddle > App Privacy (under General), then **Get Started** (or **Edit** next to Data Types).

They match `App/PrivacyInfo.xcprivacy` and the website's `/privacy` page. If one changes, change all three.

## 1. Privacy Policy URL

`https://poddle.mikecann.app/privacy` (the metadata script sets this too, on the app info).

## 2. Data collection

**Do you or your third-party partners collect data from this app?** Yes, we collect data from this app.

## 3. Data types to tick

| Section | Tick | Why |
|---|---|---|
| Contact Info | **Name** | From Sign in with Apple or Google |
| Contact Info | **Email Address** | From Sign in with Apple or Google |
| User Content | **Photos or Videos** | Screenshots attached to a "Suggest a feature" request |
| User Content | **Audio Data** | Voice notes attached to a feature request |
| User Content | **Other User Content** | The feature request's text (and the voice note's transcript) |
| Identifiers | **User ID** | The Poddle account ID |
| Identifiers | **Device ID** | The device ID and push token in `devices` |
| Usage Data | **Product Interaction** | Listening history, library, queue and stats |
| Search History | **Search History** | Discover searches, cached on the server for up to two days |
| Diagnostics | **Crash Data** | Anonymous crash and error reports sent to Sentry by App Store installs (`App/Diagnostics.swift`) |

Leave everything else unticked: Health and Fitness, Financial Info, Location, Sensitive Info, Contacts, Browsing History, Purchases, Performance Data and Other Diagnostic Data under Diagnostics, Advertising Data, Other Usage Data, Other Data, Phone Number, Physical Address, Other User Contact Info, Emails or Text Messages, Gameplay Content, Customer Support.

## 4. For each ticked type

Apple asks three things per type. The answers are the same for all of them except Search History.

**Name, Email Address, Photos or Videos, Audio Data, Other User Content, User ID, Device ID, Product Interaction:**

1. **How is it used?** Tick only **App Functionality**. (Not Third-Party Advertising, Developer's Advertising or Marketing, Analytics, Product Personalization or Other Purposes.)
2. **Is it linked to the user's identity?** **Yes.**
3. **Is it used for tracking?** **No.**

**Search History** and **Crash Data:**

1. **How is it used?** **App Functionality** only.
2. **Linked to the user's identity?** **No** (the search cache is keyed by the search, not the person; crash reports carry no account or email, only a random ID Sentry makes per install).
3. **Used for tracking?** **No.**

## 5. Check the preview

The summary on the App Privacy page should read:

- **Data Linked to You:** Contact Info, User Content, Identifiers, Usage Data
- **Data Not Linked to You:** Search History, Diagnostics
- **Data Used to Track You:** none

Then **Publish**.
