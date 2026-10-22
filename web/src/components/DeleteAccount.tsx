import { useAuthActions } from "@convex-dev/auth/react";
import { useMutation } from "convex/react";
import { useState } from "react";
import { api } from "../../../convex/_generated/api";
import { navigate } from "../lib/router";

// /me's "Delete account": the same two confirmations as the app's Profile tab.
// users:deleteAccount signs the person out on the server straight away; this
// then ends the website's session and goes home.

type Step = "idle" | "explain" | "sure" | "working";

/** `onLeaving(true)` just before deleting, so the page can drop its live queries (they'd fail once the account's gone). */
export function DeleteAccount({ onLeaving }: { onLeaving: (leaving: boolean) => void }) {
  const deleteAccount = useMutation(api.users.deleteAccount);
  const { signOut } = useAuthActions();
  const [step, setStep] = useState<Step>("idle");
  const [error, setError] = useState<string | null>(null);

  const run = async () => {
    setStep("working");
    setError(null);
    onLeaving(true);
    try {
      await deleteAccount({});
      await signOut();
      navigate("/?deleted=1", { replace: true });
    } catch {
      onLeaving(false);
      setStep("sure");
      setError("Couldn't delete your account. Check your connection and try again.");
    }
  };

  return (
    <section className="danger-zone" aria-label="Delete account">
      {step === "idle" ? (
        <button className="linkbtn" onClick={() => setStep("explain")}>Delete account</button>
      ) : step === "explain" ? (
        <div className="notice confirm-delete" role="alertdialog" aria-labelledby="delete-title">
          <b id="delete-title">Delete your Poddle account?</b>
          This deletes your library, Up Next, listening history, stats and settings, and any feature requests you've
          sent. Downloads on your devices are removed when you delete from the app there. You can't undo it.
          <div className="actions">
            <button className="btn" onClick={() => setStep("idle")}>Cancel</button>
            <button className="btn danger" onClick={() => setStep("sure")}>Continue</button>
          </div>
        </div>
      ) : (
        <div className="notice confirm-delete" role="alertdialog" aria-labelledby="delete-sure">
          <b id="delete-sure">Are you sure?</b>
          Everything goes for good, and you'll be signed out everywhere.
          {error && <p className="error">{error}</p>}
          <div className="actions">
            <button className="btn" disabled={step === "working"} onClick={() => setStep("idle")}>Keep my account</button>
            <button className="btn danger" disabled={step === "working"} onClick={() => void run()}>
              {step === "working" ? "Deleting…" : "Delete my account"}
            </button>
          </div>
        </div>
      )}
    </section>
  );
}
