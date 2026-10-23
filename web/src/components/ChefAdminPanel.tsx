import { useAuthToken } from "@convex-dev/auth/react";
import { ChefPanelMount } from "@convex-dev/feedback/react";
import { useQuery } from "convex/react";
import { api } from "../../../convex/_generated/api";
import { convexUrl } from "../lib/convexUrl";

// Chef's web panel, for its admin only (Mike): the approval queue and the
// requests. Everyone else asks for features from the app's Settings, so nobody
// else gets a button here.
export function ChefAdminPanel() {
  const admin = useQuery(api.chef.amAdmin);
  const token = useAuthToken();
  if (!admin) return null;
  return <ChefPanelMount convexUrl={convexUrl()} token={token} whatsNew={false} />;
}
