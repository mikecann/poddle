import { Layout } from "../components/Layout";
import { CONTACT_EMAIL } from "../lib/links";
import { Link } from "../lib/router";
import { useTitle } from "../lib/useShareData";

// The privacy policy the App Store listing links to. Keep it in step with what
// the backend actually stores (convex/schema.ts) and with
// docs/runbooks/app-privacy-answers.md.

export function PrivacyPage() {
  useTitle("Privacy · Poddle");
  return (
    <Layout>
      <article className="prose">
        <span className="eyebrow">Privacy</span>
        <h1>Poddle's privacy policy</h1>
        <p className="meta">Last updated 22 October 2026</p>

        <p>
          Poddle is a podcast player I (Mike Cann) made for myself, and now anyone can use it. This page says what it
          keeps about you, why, where it lives, and how to get rid of it. The short version: it keeps what it needs to
          sync your podcasts between your devices, and nothing else. No ads, no tracking, and I don't sell anything to
          anyone.
        </p>

        <h2>What Poddle stores</h2>
        <ul>
          <li>
            <b>Your account:</b> your email address and name, from Sign in with Apple or Google (and your Google profile
            photo if you use Google). If you use Apple's "Hide My Email", I only ever see the relay address.
          </li>
          <li>
            <b>Your library:</b> the shows you follow, your Up Next queue, what you've played, starred or archived, where
            you're up to in each episode, and your settings (global and per show).
          </li>
          <li>
            <b>Your listening history and stats:</b> when you listened, to what, for how long, at what speed, and with
            which settings. That's what the Stats tab and your Year in Review are made from. If you import from Overcast,
            your Overcast history comes in too.
          </li>
          <li>
            <b>Your devices:</b> a device ID, its name and type, and a push notification token, so new episodes can show
            up on your phone.
          </li>
          <li>
            <b>Feature requests:</b> if you use "Suggest a feature", what you write, plus any screenshots and voice notes
            you attach (and the words of the voice note, if you let it transcribe).
          </li>
        </ul>
        <p>
          When you search in Discover, the search goes through Poddle's server to Apple's podcast directory, and the
          results are kept for a day or two so the same search is quicker next time. They aren't tied to you.
        </p>
        <p>
          The shows and episodes themselves (titles, artwork, show notes) come from public podcast feeds and are shared by
          everyone, so they aren't yours or anyone's personal data. Downloaded episodes stay on your device.
        </p>

        <h2>Why</h2>
        <p>
          Only to run Poddle for you: to sign you in, keep your library and queue in sync across your devices, show you
          your stats, send you a notification when a new episode arrives, and read your feature requests. It's never used
          for advertising, and it's never shared with anyone for their own use.
        </p>

        <h2>Where it lives, and who handles it</h2>
        <ul>
          <li>
            <b>Convex</b> hosts Poddle's database and website, in Sydney, Australia. Everything above is stored there.
          </li>
          <li>
            <b>Apple</b> and <b>Google</b> handle signing in. They tell Poddle your email and name, and that's it.
          </li>
          <li>
            <b>Apple Push Notification service</b> delivers notifications to your iPhone, using your device's push token.
          </li>
        </ul>
        <p>
          Podcast audio and artwork are fetched from wherever each show hosts them, like any podcast app, so those hosts
          see a normal web request from your device or from Poddle's server.
        </p>

        <h2>No ads, no tracking, no selling</h2>
        <p>
          Poddle has no ads, no analytics or tracking SDKs, and doesn't follow you across other apps or websites. I don't
          sell or rent your data, and I never will.
        </p>

        <h2>Deleting your account</h2>
        <p>
          You can delete your account whenever you like: in the app, go to <b>Profile</b> and tap <b>Delete account</b>,
          or sign in on <Link to="/me">poddle.mikecann.app/me</Link> and use the <b>Delete account</b> link at the
          bottom. You're signed out straight away, and your library, queue, listening history, stats, settings, devices
          and feature requests are deleted from Poddle's database within a few minutes. Downloads on the device you
          delete from are removed too. Convex keeps daily backups for a short while, so a copy can hang around in those
          until they expire.
        </p>

        <h2>Kids</h2>
        <p>Poddle isn't made for children under 13, and doesn't knowingly collect anything from them.</p>

        <h2>Changes</h2>
        <p>If this policy changes, I'll update it here and change the date at the top.</p>

        <h2>Questions</h2>
        <p>
          Email me at <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> and I'll get back to you.
        </p>
      </article>
    </Layout>
  );
}
