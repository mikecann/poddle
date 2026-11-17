import { lazy, Suspense } from "react";
import { EpisodePage } from "./pages/EpisodePage";
import { HomePage } from "./pages/HomePage";
import { MePage } from "./pages/MePage";
import { PrivacyPage } from "./pages/PrivacyPage";
import { SupportPage } from "./pages/SupportPage";
import { ShowPage } from "./pages/ShowPage";
import { Layout, NotFound } from "./components/Layout";
import { useLocation } from "./lib/router";

// The admin Machines page brings the state machines viewer, which no public page needs.
const MachinesPage = lazy(() => import("./pages/MachinesPage"));

export function App() {
  const location = useLocation();
  const [, first = "", id = ""] = location.path.split("/");
  if (location.path === "/" || location.path === "") return <HomePage deleted={location.search.has("deleted")} />;
  if (first === "e" && id) return <EpisodePage key={id} id={id} location={location} />;
  if (first === "s" && id) return <ShowPage key={id} id={id} />;
  if (first === "me") return <MePage />;
  if (first === "admin" && id === "machines") return <Suspense fallback={null}><MachinesPage /></Suspense>;
  if (first === "privacy") return <PrivacyPage />;
  if (first === "support") return <SupportPage />;
  return <Layout><NotFound what="page" /></Layout>;
}
