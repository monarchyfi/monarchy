# Demo script (about 95 seconds)

Set up before recording: MONARCH launched on Ascend (Ascend's site or `npm run launch:testnet`), Monarchy deployed (`npm run deploy:testnet`). Wallet A is the dev and steward, wallet B a holder, wallet C the treasury recipient. Tabs open: the Monarchy site and the Elysium explorer. As a backup, the same flow runs locally with `npm run demo:local`.

| Time | Screen | Action (contract call) |
|---|---|---|
| 0–8 s | Landing page, then Kingdom | "Monarchy: lock to earn, vest in the open. Exile, Sandfall, Lodestar." The Kingdom tab shows where every fee goes. Explorer shows the MONARCH launch on AscendLaunchpad. |
| 8–22 s | Lodestar page, wallet A | Token is prefilled. The wizard shows the router address before it exists (`factory.predict`). Click **Hand over creator role** (`launchpad.transferCreator`), then **Activate Lodestar** (`factory.deploy`: accepts the role, creates the Exile pool and the Sandfall treasury stream, locks the role for good). Set the split with the two-handle slider before activating. The router dashboard appears: 20/50/30 split, "Holds the creator role", "Role locked forever". |
| 22–38 s | Lodestar page | Wallet B buys and sells MONARCH (Ascend's site or `AscendSwapper`). Click **Distribute** (`Lodestar.distribute()`). In the explorer, one transaction shows the collect, the claim, Exile's `StakeRewardAdded` for the token-side fees, the buyback swap and its burn to 0xdead, Exile's `RewardAdded` and Sandfall's `ToppedUp`. Dashboard counters jump. |
| 38–62 s | Exile page, wallet B | The page opens on **Lock MONARCH** with the tier cards. Pick **Monarch** (1 month, 4x) or drag the lock-length slider, approve and lock (`lockERC20`). Flip the switch to **Something else** to show that any token, LP or NFT can be locked, and that tokens using Lodestar earn rewards too. The lock card shows "Not cancellable", the unlock date and the reward counter ticking every 100 ms. Optional: a second wallet locks as Peasant and ticks visibly slower. **Claim** (`claimRewards`). |
| 62–82 s | Sandfall page, wallet C | The Team Treasury rolling stream fills; **Claim** (`claim`). Switch to wallet A: create a contributor vest in the numbered steps (token, recipient and amount, a 1 day cliff over 30 days, **Only me** can cancel). The unlock chart on the right redraws as you type. Create it (amber Cancellable badge, `createFixed`), and show an existing **Not cancellable** vest with its cancel button locked. |
| 82–95 s | Lodestar page, wallet A | Steward controls: propose a new split; the "Pending split change" card shows "Executable in 11h 59m" behind the 12 hour timelock (`proposeConfig`). Closing card: roadmap (other launchpads, kHYPE treasury, Ascend NFTs, a router checkbox on Ascend's launch form) and links. |

Talking points:

- No fees on any feature. MONARCH runs on its own product.
- The dev launches on Ascend's site and keeps the dev buy; only the creator fee stream moves to Lodestar.
- `distribute()` is permissionless and safe to spam: the buyback is priced from the stricter of Ascend's EMA and spot, capped at a small share of pool depth and at most every 30 minutes, so sandwiching it doesn't pay, and anything that can't go out yet waits in reserve.
- Exile rewards drip over 3 days and stop at unlock, so sniping a payout or chaining 1 day locks earns far less than a real Monarch lock.
- Our own buyback pays the 1% pool fee, half of which comes straight back to Lodestar on the next collect.
