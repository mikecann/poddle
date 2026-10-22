import { Component, type ReactNode } from "react";
import { isSignedOutError } from "../lib/sessionErrors";
import { Loading } from "./Layout";

// /me's live queries throw when the server no longer recognises the tab's
// session (the account was deleted in another tab, or its data reset) while the
// browser still holds tokens for it. Without this the throw unmounted the whole
// page and left it blank. A signed-out error signs the tab out, so it falls back
// to the sign-in form; anything else gets a message instead of an empty page.

type Props = { onSignedOut: () => void; children: ReactNode };

export class SessionBoundary extends Component<Props, { error: unknown }> {
  state = { error: null as unknown };

  static getDerivedStateFromError(error: unknown) {
    return { error };
  }

  componentDidCatch(error: unknown) {
    if (isSignedOutError(error)) this.props.onSignedOut();
  }

  render() {
    const { error } = this.state;
    if (error === null) return this.props.children;
    if (isSignedOutError(error)) return <Loading />;
    return (
      <div className="notice" role="alert">
        <b>Couldn't load your listening</b>
        Something went wrong talking to Poddle. <button className="linkbtn" onClick={() => location.reload()}>Reload the page</button>
      </div>
    );
  }
}
