import { useEffect, useState } from "react";

/** Unix seconds, ticking every `ms`. */
export function useNow(ms = 1000): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), ms);
    return () => clearInterval(t);
  }, [ms]);
  return now;
}

/** Interpolates a reward balance between polls: base + rate * elapsed, where rate is 1e18-scaled per second. */
export function useTicking(base: bigint | undefined, ratePerSecE18: bigint | undefined, ms = 100): bigint | undefined {
  const [value, setValue] = useState(base);
  useEffect(() => {
    if (base === undefined) return;
    const start = performance.now();
    setValue(base);
    if (!ratePerSecE18) return;
    const t = setInterval(() => {
      const elapsedMs = BigInt(Math.floor(performance.now() - start));
      setValue(base + (ratePerSecE18 * elapsedMs) / 1000n / 10n ** 18n);
    }, ms);
    return () => clearInterval(t);
  }, [base, ratePerSecE18, ms]);
  return value;
}

export const POLL = { query: { refetchInterval: 2000 } } as const;

/** Sets the tab title for a page. */
export function usePageTitle(title?: string) {
  useEffect(() => {
    document.title = title ? `${title} | Monarchy` : "Monarchy | Lock to earn, vest in the open";
  }, [title]);
}
