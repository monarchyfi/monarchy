import { AsciiCrown } from "../components/AsciiCrown";
import { usePageTitle } from "../lib/hooks";

/**
 * The landing page: one screen, no scroll, everything on one centre line. The crown draws the eye; the details live
 * on the Kingdom page and the tool pages.
 */
export function Home() {
  usePageTitle();
  return (
    <div className="landing">
      <h1 className="wordmark">Monarchy</h1>
      <AsciiCrown className="landing-crown" />
      <p className="tagline">Steal the Crown</p>
      <p className="landing-sub">Lock to earn. The kingdom shares everything with those who stay.</p>
      <div className="landing-links">
        <span className="landing-note">Locks, vesting and rewards for lockers. No fees.</span>
        <span className="landing-out">
          <a href="https://docs.monarchy.fi" target="_blank" rel="noreferrer">
            Docs <span aria-hidden="true">↗</span>
          </a>
          <a href="https://x.com/monarchyfi" target="_blank" rel="noreferrer" aria-label="Monarchy on X">
            <XLogo /> <span aria-hidden="true">↗</span>
          </a>
        </span>
      </div>
    </div>
  );
}

function XLogo() {
  return (
    <svg viewBox="0 0 24 24" width="13" height="13" aria-hidden="true" fill="currentColor">
      <path d="M3 3 L10.2 12.6 L3.2 21 H5.6 L11.3 14.1 L16.4 21 H21 L13.4 10.8 L19.9 3 H17.5 L12.3 9.3 L7.6 3 Z" />
    </svg>
  );
}

export function days(seconds: number): string {
  const d = seconds / 86400;
  if (d === 30) return "1 month";
  return `${d} day${d === 1 ? "" : "s"}`;
}
