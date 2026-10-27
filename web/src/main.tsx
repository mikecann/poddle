import { ConvexAuthProvider } from "@convex-dev/auth/react";
import { ConvexReactClient } from "convex/react";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { api } from "../../convex/_generated/api";
import { App } from "./App";
import { convexUrl } from "./lib/convexUrl";
// Poppins is the landing page's one typeface (the landing-page-design skill experiment).
import "@fontsource/poppins/400.css";
import "@fontsource/poppins/500.css";
import "@fontsource/poppins/600.css";
import "@fontsource/poppins/700.css";
import "./styles.css";

const convex = new ConvexReactClient(convexUrl());

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ConvexAuthProvider client={convex} api={{ refreshSession: api.auth.refreshSession, signOut: api.auth.signOut }}>
      <App />
    </ConvexAuthProvider>
  </StrictMode>,
);
