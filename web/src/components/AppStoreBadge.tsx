import { APP_STORE_LIVE, APP_STORE_URL } from "../lib/links";
import { AppleLogo } from "./Icons";

// The black "Download on the App Store" badge, drawn here rather than hotlinked.
// Until APP_STORE_LIVE (lib/links.ts) is true it reads "Coming soon to the App
// Store" and isn't a link.

export function AppStoreBadge() {
  const label = (
    <>
      <AppleLogo className="appstore-logo" />
      <span>
        <small>{APP_STORE_LIVE ? "Download on the" : "Coming soon to the"}</small>
        <b>App Store</b>
      </span>
    </>
  );
  if (APP_STORE_LIVE) return <a className="appstore" href={APP_STORE_URL}>{label}</a>;
  return <span className="appstore soon">{label}</span>;
}
