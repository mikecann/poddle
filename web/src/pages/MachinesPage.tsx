import { MachinesViewer } from "@convex-dev/state-machines/viewer";
import "@convex-dev/state-machines/viewer.css";
import { useConvexAuth, useQuery } from "convex/react";
import { api } from "../../../convex/_generated/api";
import { Layout, Loading } from "../components/Layout";
import { SignIn } from "../components/SignIn";
import { useTitle } from "../lib/useShareData";

// The admin Machines page: every state machine in the backend (the Overcast
// import, the feed fetch claim), drawn from the rules it runs, with the rows in
// each state. Only Chef's admin (Mike) sees it; convex/machinesViewer.ts checks
// that on every query, so this page's own check is only for what it shows.
// Loaded on its own (App.tsx), so the public pages don't carry the viewer.
export default function MachinesPage() {
  const { isAuthenticated, isLoading } = useConvexAuth();
  const admin = useQuery(api.chef.amAdmin, isAuthenticated ? {} : "skip");
  useTitle("Machines · Poddle", { noindex: true });
  if (isLoading || (isAuthenticated && admin === undefined)) return <Layout><Loading /></Layout>;
  if (!isAuthenticated) {
    return (
      <Layout>
        <section className="me-signin">
          <h1>Sign in to see the machines</h1>
          <SignIn returnTo="/admin/machines" />
        </section>
      </Layout>
    );
  }
  if (!admin) {
    return (
      <Layout>
        <section className="me-signin">
          <h1>This page is for Poddle's admin</h1>
        </section>
      </Layout>
    );
  }
  return (
    <div className="machines-page">
      <MachinesViewer functions={api.machinesViewer} config={{ settings: { theme: "system" } }} />
    </div>
  );
}
