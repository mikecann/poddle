import { EpisodePage } from "./pages/EpisodePage";
import { HomePage } from "./pages/HomePage";
import { MePage } from "./pages/MePage";
import { ShowPage } from "./pages/ShowPage";
import { Layout, NotFound } from "./components/Layout";
import { useLocation } from "./lib/router";

export function App() {
  const location = useLocation();
  const [, first = "", id = ""] = location.path.split("/");
  if (location.path === "/" || location.path === "") return <HomePage />;
  if (first === "e" && id) return <EpisodePage key={id} id={id} location={location} />;
  if (first === "s" && id) return <ShowPage key={id} id={id} />;
  if (first === "me") return <MePage />;
  return <Layout><NotFound what="page" /></Layout>;
}
