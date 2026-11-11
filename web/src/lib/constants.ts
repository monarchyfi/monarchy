// Lengths the UI shows before (or instead of) reading them from the contracts.
// If the contracts change, these are the only lines to update.

/** Exile's reward drip, in days. The live value is read from Exile.DRIP() when the chain answers. */
export const DEFAULT_DRIP_DAYS = 3;

/** The Team Treasury stream window proposed in the Lodestar activation form, in days. Live streams show their own window. */
export const DEFAULT_TREASURY_WINDOW_DAYS = 7;

/** How often the team calls Lodestar.distribute() from team funds. Anyone else can call it at any time. */
export const DISTRIBUTE_EVERY_HOURS = 3;

/** One line on who calls distribute, shown next to the drip stats and the Distribute button. */
export const DISTRIBUTE_NOTE = `Distributed every ${DISTRIBUTE_EVERY_HOURS} hours by the team, and anyone can call it.`;

/** Exile.MAX_BUCKETS_PER_CALL: the hours one catch-up transaction moves the reward pool forward. */
export const EXILE_CATCH_UP_HOURS = 720;

/** Gas above which the Distribute card catches Exile's reward pool up in its own transactions first, like the keeper
 * (tools/keeper-distribute.sh). A quiet day costs far less; a long pause with locks expiring every hour costs millions. */
export const CATCH_UP_ALONE_ABOVE_GAS = 2_000_000n;

/** The MONARCHY token's contract address, shown in the nav with click to copy. Unset, the nav shows "CA: soon".
 * For now it holds the standard burn address so the copy button can be tried; swap in the token's address at launch. */
export const MONARCHY_CA: `0x${string}` | undefined = "0x000000000000000000000000000000000000dEaD";

/** The settings MONARCHY's own Lodestar will launch with: 70% of the quote-side fees to Exile lockers, 20% to buyback
 * and burn and 10% to the Team Treasury (other coins start from the form's 50/20/30 and pick their own). While a sample
 * token stands in for MONARCHY, the Kingdom page shows these rather than the sample token's own. */
export const MONARCHY_SETTINGS = {
  burnBps: 2000,
  holdersBps: 7000,
  treasuryBps: 1000,
  tokenToHolders: true,
  tiers: [
    { name: "Peasant", minDuration: 86400, multiplierBps: 5000 },
    { name: "Knight", minDuration: 3 * 86400, multiplierBps: 10000 },
    { name: "Duke", minDuration: 7 * 86400, multiplierBps: 20000 },
    { name: "Monarch", minDuration: 30 * 86400, multiplierBps: 40000 },
  ],
};

/** Whether a token is MONARCHY itself rather than a sample token standing in for it. */
export const isMonarchy = (token?: string) => !!token && !!MONARCHY_CA && token.toLowerCase() === MONARCHY_CA.toLowerCase();
