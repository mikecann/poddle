import { ConvexAuthProvider } from "@convex-dev/auth/react";
import { ConvexReactClient } from "convex/react";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { api } from "../../convex/_generated/api";
import { App } from "./App";
import { convexUrl } from "./lib/convexUrl";
import "./styles.css";

const convex = new ConvexReactClient(convexUrl());

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ConvexAuthProvider client={convex} api={{ refreshSession: api.auth.refreshSession, signOut: api.auth.signOut }}>
      <App />
    </ConvexAuthProvider>
  </StrictMode>,
);
