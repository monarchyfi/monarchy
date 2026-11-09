import { Fragment, useEffect, useState } from "react";
import { NavLink, Route, Routes, useLocation } from "react-router-dom";
import { useConnect, useConnection, useConnectors } from "wagmi";
import { Connect } from "./components/Connect";
import { CrownSolid } from "./components/Crown";
import { CastleGlyph, GardenGlyph, GateGlyph, HourglassGlyph, StarGlyph } from "./components/NavGlyphs";
import { NetworkNotice, TestnetStrip } from "./components/States";
import { MONARCHY_CA } from "./lib/constants";
import { short } from "./lib/format";
import { useMock } from "./lib/wagmi";
import { ExilePage } from "./pages/Exile";
import { GardenPage } from "./pages/Garden";
import { Home } from "./pages/Home";
import { KingdomPage } from "./pages/Kingdom";
import { LodestarPage } from "./pages/Lodestar";
import { NotFound } from "./pages/NotFound";
import { SandfallPage } from "./pages/Sandfall";

const LINKS = [
  { to: "/kingdom", label: "Kingdom", hint: "How it works and live stats", key: "kingdom", glyph: <CastleGlyph /> },
  { to: "/exile", label: "Exile", hint: "Lock to earn", key: "exile", glyph: <GateGlyph /> },
  { to: "/sandfall", label: "Sandfall", hint: "Vesting in the open", key: "sandfall", glyph: <HourglassGlyph /> },
  { to: "/lodestar", label: "Lodestar", hint: "Pay a coin's fees to its lockers", key: "lodestar", glyph: <StarGlyph /> },
];

// the word, with the tool's mark hidden in front of it until hover
function LinkLabel({ l }: { l: (typeof LINKS)[number] }) {
  return (
    <>
      <span className="nl-word">{l.label}</span>
      <span className="nl-icon" aria-hidden="true">
        {l.glyph}
      </span>
    </>
  );
}

/** The MONARCHY token's contract address, shortened, and a click copies it. Until launch it reads "CA: soon". */
/** Copies text, falling back to a hidden textarea where the async clipboard is blocked (an http page, an iframe). */
async function copyText(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.setAttribute("readonly", "");
    ta.style.cssText = "position:fixed;top:0;left:0;opacity:0";
    document.body.appendChild(ta);
    ta.select();
    const ok = document.execCommand("copy");
    ta.remove();
    return ok;
  }
}

function CopyMark({ done }: { done: boolean }) {
  return (
    <svg className="ca-ico" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.1" aria-hidden="true">
      {done ? <path d="M2 6.4 4.6 9 10 3.2" /> : <path d="M4 4h6v6.5H4ZM2 8V1.5h6" />}
    </svg>
  );
}

function ContractChip({ className }: { className?: string }) {
  const [copied, setCopied] = useState(false);
  const token = MONARCHY_CA;
  if (!token) {
    return (
      <span className={`ca ca-soon ${className ?? ""}`}>
        <span className="ca-k">CA</span>
        <span className="ca-v">soon</span>
      </span>
    );
  }
  const copy = async () => {
    if (await copyText(token)) {
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    }
  };
  return (
    <button type="button" className={`ca ${copied ? "ca-copied" : ""} ${className ?? ""}`} onClick={copy} title={`${token}, click to copy`} aria-label={`Contract address ${token}, click to copy`}>
      <span className="ca-k">CA</span>
      <span className="ca-v">{copied ? "Copied" : short(token)}</span>
      <CopyMark done={copied} />
    </button>
  );
}

export function App() {
  const [menuOpen, setMenuOpen] = useState(false);
  const { pathname } = useLocation();
  const home = pathname === "/";
  useMockAutoConnect();

  // close the phone menu and go to the top on every navigation
  useEffect(() => {
    setMenuOpen(false);
    window.scrollTo(0, 0);
  }, [pathname]);

  return (
    <div className={`app ${home ? "app-home" : ""}`}>
      <TestnetStrip />
      <header className="nav-wrap">
        <nav className="nav" aria-label="Main">
          <div className="nav-left">
            <NavLink to="/" end className="nav-crown nav-crown-m" aria-label="Monarchy home">
              <CrownSolid />
            </NavLink>
            {/* the Garden, where the analytics live: an icon on its own at the far left of the bar, apart from the tabs */}
            <NavLink to="/garden" className="nl nl-garden nav-garden" aria-label="Garden" data-tip="Garden">
              <GardenGlyph />
            </NavLink>
          </div>
          {/* the four tabs, with the crown for home in the middle */}
          <div className="nav-links">
            {LINKS.map((l, i) => (
              <Fragment key={l.to}>
                {i === 2 && (
                  <NavLink to="/" end className="nav-crown" aria-label="Monarchy home">
                    <CrownSolid />
                  </NavLink>
                )}
                <NavLink to={l.to} className={`nl nl-${l.key}`}>
                  <LinkLabel l={l} />
                </NavLink>
              </Fragment>
            ))}
          </div>
          <div className="nav-right">
            <ContractChip />
            {/* the landing page is for looking; connecting happens on the tool pages */}
            {!home && <Connect className="nav-connect" />}
            <button
              className="menu-btn"
              aria-label={menuOpen ? "Close menu" : "Open menu"}
              aria-expanded={menuOpen}
              aria-controls="mobile-menu"
              onClick={() => setMenuOpen((o) => !o)}
            >
              <span className={`burger ${menuOpen ? "open" : ""}`} aria-hidden="true">
                <i />
                <i />
                <i />
              </span>
            </button>
          </div>
        </nav>
        {menuOpen && (
          <div className="menu" id="mobile-menu">
            <NavLink to="/garden" className="menu-link nl nl-garden">
              <span className="nl">
                <span className="nl-word">Garden</span>
              </span>
              <span className="menu-hint">Every lock and vest, grown in the open</span>
            </NavLink>
            {LINKS.map((l) => (
              <NavLink key={l.to} to={l.to} className={`menu-link nl nl-${l.key}`}>
                <span className="nl">
                  <LinkLabel l={l} />
                </span>
                <span className="menu-hint">{l.hint}</span>
              </NavLink>
            ))}
            <ContractChip className="menu-ca" />
          </div>
        )}
      </header>
      <NetworkNotice />
      <main>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/kingdom" element={<KingdomPage />} />
          <Route path="/lodestar" element={<LodestarPage />} />
          <Route path="/exile" element={<ExilePage />} />
          <Route path="/sandfall" element={<SandfallPage />} />
          <Route path="/garden" element={<GardenPage />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
      </main>
      {!home && (
        <footer className="foot">
          <div className="foot-brand">
            <span>MONARCHY</span>
            <span className="foot-sep" aria-hidden="true" />
            <span>Locks, vesting and rewards for lockers. No fees.</span>
          </div>
          <div className="foot-links">
            <a href="https://x.com/monarchyfi" target="_blank" rel="noreferrer">
              X
            </a>
            <a href="https://docs.monarchy.fi" target="_blank" rel="noreferrer">
              Docs
            </a>
            <a href="https://github.com/monarchy-fi/monarchy" target="_blank" rel="noreferrer">
              GitHub
            </a>
          </div>
        </footer>
      )}
    </div>
  );
}

/** With `?mock` on a dev server, connect anvil's first account as soon as the page loads. */
function useMockAutoConnect() {
  const { status } = useConnection();
  const connectors = useConnectors();
  const connect = useConnect();
  useEffect(() => {
    if (!useMock || status !== "disconnected" || connect.isPending) return;
    const c = connectors[0];
    if (c) connect.mutate({ connector: c });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status, connectors]);
}
