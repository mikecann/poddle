import { Layout } from "../components/Layout";
import { Link } from "../lib/router";
import { useTitle } from "../lib/useShareData";
import { CONTACT_EMAIL } from "./PrivacyPage";

// The support page the App Store listing links to.

export function SupportPage() {
  useTitle("Support · Poddle");
  return (
    <Layout>
      <article className="prose">
        <span className="eyebrow">Support</span>
        <h1>Help with Poddle</h1>
        <p className="lede">
          A few things people ask. If yours isn't here, email me at{" "}
          <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a> and I'll do my best to help.
        </p>

        <h2>How do I bring my podcasts over from Overcast?</h2>
        <p>
          Sign in at <a href="https://overcast.fm/account">overcast.fm/account</a> and tap <b>All data</b> under OPML
          export (that one has your play history), and save the file. Then in Poddle, go to <b>Profile</b>, tap{" "}
          <b>Import from Overcast</b> and pick that file. Poddle brings over your shows, what you've
          played, where you're up to, your starred episodes and your listening history, so your stats start with
          everything you've already listened to. Your Overcast queue becomes your Up Next. It can take a few minutes for a
          big library while it fetches every feed.
        </p>

        <h2>How do speed and Smart Speed work?</h2>
        <p>
          Tap the speed button on the Now Playing screen to speed up (or slow down). Poddle's "Speech-tuned" speed-up is
          made for voices, so people sound like themselves rather than chipmunks. <b>Smart Speed</b> trims the silences
          between words, and <b>Voice Boost</b> evens out the volume so quiet hosts are easier to hear. Swipe left on Now
          Playing to change these, and turn on <b>Customize for</b> that show if you want different settings for one
          show.
        </p>

        <h2>Will it download over mobile data?</h2>
        <p>
          Not unless you say so. By default Poddle only downloads on Wi-Fi, and streaming always works anywhere. If you're
          out and want an episode now, you can allow mobile downloads for an hour, three hours or until tomorrow (in{" "}
          <b>Profile</b>, under Downloads, or from the prompt you get when you tap download), or switch to "Wi-Fi and mobile
          data" for good.
        </p>

        <h2>How do I delete my account?</h2>
        <p>
          In the app, go to <b>Profile</b> and tap <b>Delete account</b>. Or sign in at{" "}
          <Link to="/me">poddle.mikecann.app/me</Link> and use the <b>Delete account</b> link at the bottom. It deletes
          your library, queue, history, stats and settings, and you can't undo it. The <Link to="/privacy">privacy
          policy</Link> has the details.
        </p>

        <h2>Something else?</h2>
        <p>
          Email <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>. If it's an idea for Poddle, you can also tap{" "}
          <b>Suggest a feature</b> in Profile.
        </p>
      </article>
    </Layout>
  );
}
