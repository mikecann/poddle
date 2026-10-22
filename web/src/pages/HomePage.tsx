import { useConvexAuth } from "convex/react";
import { useTitle } from "../lib/useShareData";
import { HOME_TITLE } from "../lib/links";
import { Landing } from "./Landing";

export function HomePage({ deleted = false }: { deleted?: boolean }) {
  const { isAuthenticated } = useConvexAuth();
  useTitle(HOME_TITLE);
  return <Landing signedIn={isAuthenticated} deleted={deleted} />;
}
