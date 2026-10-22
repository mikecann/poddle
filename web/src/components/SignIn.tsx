import { useAuthActions } from "@convex-dev/auth/react";
import { useSignInWithApple } from "@convex-dev/auth/methods/apple/react";
import { useOauth, type OauthFlowError } from "@convex-dev/auth/methods/oauth/react";
import { useSignInWithGoogle } from "@convex-dev/auth/methods/google/react";
import { useMutation } from "convex/react";
import { useState, type FormEvent } from "react";
import { api } from "../../../convex/_generated/api";
import { testSignInEnabled } from "../lib/convexUrl";
import { AppleLogo, GoogleLogo } from "./Icons";

// Sign in with Apple or Google through Convex Auth v2's web flow: the button
// goes to the provider, which comes back to this page with a code that the
// oauth() client (registered by ConvexAuthProvider) redeems on load.

function flowMessage(error: OauthFlowError | null): { title: string; body: string } | null {
  if (!error) return null;
  switch (error.error) {
    case "REJECTED": {
      const code = (error.data as { code?: string } | undefined)?.code;
      if (code === "inviteOnly") {
        return {
          title: "Poddle is invite-only for now",
          body: "It's just a handful of us on it at the moment, so that account isn't on the list yet. If you think it should be, give me a shout.",
        };
      }
      return { title: "Couldn't sign you in", body: (error.data as { message?: string } | undefined)?.message ?? "The server said no." };
    }
    case "ACCESS_DENIED":
      return { title: "Sign-in cancelled", body: "No worries, try again whenever you like." };
    case "EXPIRED":
    case "INVALID_FLOW":
      return { title: "That sign-in timed out", body: "Give it another go." };
    case "OTHER_ERROR":
      return { title: "Couldn't sign you in", body: "Something went wrong on the way back from the sign-in page. Give it another go." };
  }
}

export function SignIn({ returnTo = "/me" }: { returnTo?: string }) {
  const apple = useSignInWithApple(api.auth);
  const google = useSignInWithGoogle(api.auth);
  const { flowError } = useOauth();
  const [startError, setStartError] = useState<string | null>(null);
  const message = flowMessage(flowError);
  const redirectTo = new URL(returnTo, window.location.origin).toString();

  const start = async (signIn: typeof apple.signIn) => {
    setStartError(null);
    const result = await signIn({ redirectTo });
    if (result.status === "error") setStartError("Couldn't start signing in. Check your connection and try again.");
  };

  return (
    <div className="signin">
      {message && (
        <div className={`notice ${flowError?.error === "REJECTED" ? "invite" : ""}`} role="alert">
          <b>{message.title}</b>
          <p>{message.body}</p>
        </div>
      )}
      <button className="btn lg apple" onClick={() => start(apple.signIn)}>
        <AppleLogo /> Sign in with Apple
      </button>
      <button className="btn lg google" onClick={() => start(google.signIn)}>
        <GoogleLogo /> Sign in with Google
      </button>
      {startError && <p className="error">{startError}</p>}
      {testSignInEnabled && <TestSignIn />}
    </div>
  );
}

/** Dev builds only: sign in as someone without Apple or Google (auth:signInForTesting). */
function TestSignIn() {
  const signInForTesting = useMutation(api.auth.signInForTesting);
  const { setSession } = useAuthActions();
  const [email, setEmail] = useState("mike.cann@gmail.com");
  const [error, setError] = useState<string | null>(null);
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    try {
      const result = await signInForTesting({ email });
      await setSession(result.tokens);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  };
  return (
    <form className="testsignin" onSubmit={submit}>
      <label className="cap" htmlFor="test-email">Test sign-in (dev only)</label>
      <div>
        <input id="test-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} />
        <button className="btn" type="submit">Sign in</button>
      </div>
      {error && <p className="error">{error}</p>}
    </form>
  );
}
