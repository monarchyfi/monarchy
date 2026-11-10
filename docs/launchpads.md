# Monarchy on Volta, Montra, ElysPump, Boxa and Kleos

**Lock to earn the fees.** Volta, Montra, ElysPump, Boxa and Kleos already split each coin's trading fee between the creator, the platform and (on most of them) the holders and a buyback, so another fee splitter adds nothing there. What they don't have is a reason to lock. Monarchy takes the creator's share of the tax and pays it to the holders who lock the coin in Exile, by tier from Peasant (0.5x for a day) to Monarch (4x for a month), with a slice bought back and burned and a slice streamed to the team in the open. Locked coins keep earning the coin's own holder dividends too: Exile claims them and passes them on to the lockers.

All five launchpads are Uniswap v4 hooks on Elysium mainnet (chain 99901). Every supported coin trades against native HYPE and the fee is taken in HYPE, so a router on these launchpads earns and pays out HYPE. One Lodestar implementation serves them all, and Ascend v5's routers too ([ascend-v5.md](ascend-v5.md)); what differs per launchpad lives in a small adapter (`contracts/src/sources/`). The website lists the launchpads in this order: Ascend, Volta, Montra, ElysPump, Boxa, Kleos.

Eleos was supported until November 9, 2026, and was dropped: its adapter, fork tests and site flow are gone. BetweenQuotes (betweenquotes.xyz) was looked at the same day and isn't supported: none of its Elysium coins is paired with native HYPE (they are quoted in stock tokens such as KNTQ), its coins start on a bonding curve, and its launches happen mainly on HyperEVM with Elysium mirrors.

```
  coin's tax (HYPE) ──▶ launchpad hook ── its own split, set at launch ──▶ holders' dividends (inside the coin or hook)
                              │                                           ──▶ the launchpad's buyback, platform fee
                              │ creator share
                              ▼
  creator ──hands the role──▶ Lodestar ◀── distribute() by the keeper or anyone
                              │
                              ├─ holdersBps (50%) ──▶ Exile.notifyReward{value} ──▶ 3 day drip to lockers by points
                              ├─ burnBps (20%) ─────▶ V4Swapper ──▶ buy the coin ──▶ burned (phase 2; in reserve until then)
                              └─ treasuryBps (30%) ─▶ Sandfall.topUp{value} ──▶ rolling 7 day stream to the Team Treasury

  Exile.harvest(coin) ──▶ claims the dividends Exile earns on locked coins ──▶ the same pool, same drip
```

## What each launchpad supports

| | Volta (volta.family) | Montra (montramarkets.xyz) | ElysPump (elysp.com) | Boxa (boxa.club) | Kleos (thekleos.xyz) |
|---|---|---|---|---|---|
| Hooks the adapter knows | the PositionManager `0x3aB8…E5dC`, every Volta pool's hook | the launch hook `0x6b12…F8EC` | v2 and v3 (the same contract on two pool managers) | main, pairs, meme pairs, uni launcher, and the newer launcher's hook `0x10F1…2aEC` (since November 9) | A and B (single quote), C (multi-quote), and D `0x0fa7…2acC` (hook C's code, since November 9) |
| Pool manager | `0xE2e1…23F1` (fee 0, tick spacing 60) | `0xE2e1…23F1` (dynamic fee, tick spacing 200) | v2 on ElysPump's own `0x5fb0…9600`, v3 on `0xE2e1…23F1` | `0x06C6…b2c4`; the uni launcher's and newer launcher's hooks run on `0xE2e1…23F1` | `0xb308…2490`; hook D runs on `0xE2e1…23F1` |
| Handover | one step: the creator NFT's `transferFrom(creator, to, id)` | one step: `updateRecipient(poolId, to)`, from the current recipient | one step: `setFeeReceiver(coin, to)`, from the current fee receiver | two steps: `proposeCreator(poolId, to)`, then `acceptCreator(poolId)` | one step: `transferCreator(coin, to)` |
| Who is the creator | the holder of the coin's creator NFT, `ownerOf(tokenId(coin))` on `0xac46…02c7` | the pool's recipient, `recipientOf(coin.poolId())` on the hook | the fee receiver, word 1 of `launches(coin)` on the hook | the pool's creator in `pools(poolId)` | `taxOf(coin).creator` |
| How the router is paid | the PositionManager distributes a pool's fees once they reach 0.01 HYPE and credits the creator share to the NFT's holder in Volta's fee escrow `0x3D36…D9a5` (`balances(router, 0)`), claimed with `withdrawFees(0, router, false)` on the escrow | held per pool (`tab(poolId)` plus `pendingCreator(poolId)`), claimed with `claim(poolId, router)` | credited at every trade to `owed(router, 0)`, claimed with `claim(0)` | `claimable(router)`, claimed with `claim(router)` (later hooks: `claim(0, router)`) | `creatorFees(router)`, claimed with `claimCreatorFees()` (hook C: per quote) |
| Fees earned before the handover | credited per address, so they stay the creator's (what the PositionManager hasn't distributed yet goes to whoever holds the NFT when it does) | held per pool, so they move with the role: the activation script and the site claim them for the creator first | held per address, so they stay the creator's | held per address, so they stay the creator's | held per address, so they stay the creator's |
| Holder dividends | paid by Volta's fee executor to wallets holding at least 0.1% of the supply; contracts, Exile included, are left out | none: a coin either pays its creator side to one recipient or to its holders | inside the coin, `claim()` (pays the caller; it flushes the hook's pending holder share first) | in the hook, `claimRewards(coin, recipient)` (the holder) | inside the coin, `claimRewards(holder)` (the holder) |
| Exile harvest | none (Exile earns no holder share) | none | `coin.claim()`, called by Exile | `hook.claimRewards(coin, exile)` | `coin.claimRewards(exile)` |
| Not supported | coins whose creator share is 0 (`NoCreatorShare`), coins quoted in KNTQ or $VOLTA | coins that pay their holders (`FeesGoToHolders`: Montra never lets them change recipient), coins paid to a splitter contract (only the splitter could activate, and it can't call the factory), coins quoted in anything but HYPE | coins with a fee receiver share of 0 (`NoReceiverShare`), the four coins quoted in KNTQ, and ElysPump's first launchpad (`0x5afe…6fe3`, 47 coins on Uniswap v3) | coins on the newer launcher's hook with a holder share (on a mainnet fork its holder share never reached a holder, so Exile can't be shown to pass it on), coins quoted in anything but HYPE | coins on hooks C and D with a holder share (paid in stock tokens through a separate distributor), coins quoted in anything but HYPE |

A coin on a hook the adapter doesn't know reverts with `UnsupportedHook`; a pair quoted in another token reverts with `QuoteUnsupported`. Volta and Montra coins name their launchpad themselves (a Volta coin's `flaunch()` is its creator NFT, a Montra coin's `poolId()` and `hook()` its pool), and the adapters check that against the launchpad's own records, so a lookalike token that names a real pool borrows nothing. A new hook generation is a config change, not a redeploy: the adapter's owner calls `addHook(hook, kind)`. The registry only grows, and a hook's kind can't change once added.

## Activating a coin

The creator runs `contracts/script/ActivateLaunchpad.s.sol` from the address the launchpad records as the coin's creator. It works out the order from the launchpad, so a creator can't get it backwards.

```bash
export RPC_URL=<an Elysium mainnet RPC>
export PRIVATE_KEY=<the creator's key>
LAUNCHPAD=volta TOKEN=0xCoin TREASURY=0xTeamTreasury \
  forge script contracts/script/ActivateLaunchpad.s.sol --rpc-url $RPC_URL --broadcast --slow
```

`TREASURY` receives the Team Treasury stream and can never be changed. The rest defaults to MONARCH's settings: 20% buyback and burn / 50% lockers / 30% Team Treasury streamed over 7 days, the Peasant-Knight-Duke-Monarch tiers, and the creator role locked to the router forever. `BURN_BPS`, `HOLDERS_BPS`, `TREASURY_BPS`, `MAX_SLIPPAGE_BPS`, `TREASURY_WINDOW`, `LOCK_FOREVER=false` and `SWAPPER` override them (see `.env.example`).

What the script sends, per launchpad:

- **Boxa (two steps, like Ascend).** `predict(coin, 0)` gives the router address. The creator calls `proposeCreator(poolId, router)` on the coin's hook, then `factory.deploy(params)`, which creates the router, its Exile pool and Sandfall stream, and accepts the role in the same transaction. Nobody else can deploy that router: the factory checks that the caller is the creator and that the predicted router is the one proposed. Fees the creator earned before stay claimable by the creator on Boxa.
- **Volta (one step).** Run by the holder of the coin's creator NFT (`LAUNCHPAD=volta`). `factory.deploy(params)`, which checks the caller holds the NFT, then the NFT's `transferFrom(creator, router, id)`. The router stores two call targets at initialize: the NFT (its `hook`, which holds the role) and Volta's fee escrow (its `payer`, which pays the fees), both read from the adapter once and never changed. Volta credits the creator share by address as the PositionManager distributes each pool's fees, so fees credited before stay the creator's to withdraw from the escrow; what the PositionManager hasn't distributed yet (under 0.01 HYPE) goes to whoever holds the NFT when it does.
- **Kleos (one step).** `factory.deploy(params)`, then `transferCreator(coin, router)` on the hook. Kleos keeps creator fees per address, so fees earned before stay the creator's to claim with `claimCreatorFees()`. Kleos's hooks ask Arbitrum's ArbSys precompile about their caller, which forge's local EVM doesn't have; the script stubs it for its own run, and the broadcast needs `--skip-simulation` so forge doesn't simulate a second time without the stub.
- **ElysPump (one step).** Run by the coin's fee receiver (`LAUNCHPAD=elyspump`). `factory.deploy(params)`, then `setFeeReceiver(coin, router)` on the hook, which only the current fee receiver can call and which takes effect at once. ElysPump keeps receiver fees per address, so fees earned before stay the receiver's to claim with `claim(0)` on the hook. The script builds every one-step hand-over from the adapter's `transferOutCalls`.
- **Montra (one step).** Run by the pool's recipient (`LAUNCHPAD=montra`). `factory.deploy(params)`, then `updateRecipient(poolId, router)` on the hook. Montra keeps the creator side per pool, so what the recipient hasn't claimed would move to the router with the role: the script first calls `claim(poolId, creator)`, so the creator keeps what they earned (`CLAIM_FIRST=false` skips this and lets the router route it). The site offers the same claim as an optional step before the hand-over.

If the second transaction of a one-step activation doesn't land, run the script again: it sees the router and only hands the role over. A router without the role earns nothing and the keeper skips it.

If a creator sent the role to the predicted address before the router existed, nothing on chain proves who sent it, so `deploy` refuses everyone. The script prints the `rescueDeploy(params, steward)` calldata instead; the factory owner checks off chain who sent the role and deploys the router with the creator's settings.

If a creator sent the role to the router of another coin on the same launchpad (for example an address copied from the wrong coin's page), `rescueDeploy` covers that too, and the script prints its calldata the same way. The factory deploys the coin's own router and has the router holding the role pass it on with `releaseForeignRole`, which only the factory can call, which refuses the router's own coin, and which the factory only calls with the new router as the recipient. What the coin earned while the wrong router held the role can't always be brought back: Volta, Kleos and ElysPump keep creator fees per address, so the wrong router claims them with its own and routes them to its own lockers. On Montra the fees stay with the pool and move on with the role, but the wrong router can't claim them (its adapter only claims its own coin's pool), so they reach the coin's own router after the rescue. Boxa needs none of this: a wrong `proposeCreator` is undone by proposing again, and `rescueDeploy` refuses Boxa coins.

A coin whose holder share Exile can't pass on to lockers is refused at deploy with `HoldersSplitActive` (today only Kleos hook C coins with a holder share). An ElysPump coin launched with a fee receiver share of 0 is refused with `NoReceiverShare`, and a Volta coin with a creator share of 0 with `NoCreatorShare`: their fees go to the platform, the holders and the coin's own buybacks, so a router would have nothing to route, and the shares can't change after launch. A Montra coin that pays its holders is refused with `FeesGoToHolders`.

## Fees

- **The launchpad's own split doesn't change.** The tax rate and the split between creator, holders, buyback and platform were set when the coin launched. The router only ever receives the creator share. For lockers to earn the whole tax that a launchpad pays creators, the coin should launch with its fee going to the creator (Volta's creator split, ElysPump's receiver share, Boxa's creator share, Kleos `creatorBps`; on Montra the whole creator side goes to the recipient); a share left to ElysPump's, Boxa's or Kleos's own holder dividends still reaches lockers through the harvest, but Volta's holder share does not (contracts are left out).
- **Handing the role out.** On Montra (and on Ascend v5) the creator side waits by pool, not by address, so when a router hands its role on, whatever the pool holds unclaimed goes with it. That only happens when the role isn't locked to the router (a steward's `transferCreatorOut` after the lock ends) or in an upgrade, which goes to the same coin's newer router. The keeper distributes every 3 hours, so at most a few hours of fees can leave this way, and a role locked forever never leaves except by upgrade. Volta, ElysPump, Boxa and Kleos credit fees by address, so a router keeps what it earned before a hand-out and can still distribute it.
- **Routing.** `distribute()` runs the adapter's collect and claim calls (Volta `withdrawFees` on the escrow, ElysPump `claim(0)`, Boxa `claim`, Kleos `claimCreatorFees`, Montra `claim(poolId, router)`) and then splits the router's HYPE balance: lockers through `Exile.notifyReward{value}`, the Team Treasury through `Sandfall.topUp{value}`, buyback through the swapper. HYPE sent to the router any other way is routed the same way. The router only calls its own hook and, on Volta, the payer it stored at initialize, and pays nothing out except to Exile, Sandfall, the swapper and the burn sink.
- **Token side.** These launchpads pay creators no fees in the coin, so the token side is normally 0; any coins the router holds go to lockers (the default) or are burned.
- **Volta's platform cut.** Volta keeps 30% of each trade's fee (`PROTOCOL_SHARE`) and splits the rest by the coin's creator, buyback and holder shares, set at launch. A coin's swap fee is 1% to 5% (`currentSwapFee(poolId, true)`, which `swapCostBps` reads; a launch can start higher with an anti-snipe fee of up to 30% that falls over its first minutes). So a coin with a 3% fee and all of its split to the creator pays the router 2.1% of every trade. On November 9, 2026, 840 of Volta's 898 coins were quoted in HYPE, and 384 of those paid their creator a share.
- **Montra's tiers.** Every trade pays the coin's tier, 1%, 2%, 3%, 5% or 10%. 0.4% goes to Montra, the pool's liquidity providers take an LP fee once the pool passes its LP line, and the rest, the creator side, waits in the hook for the pool's recipient. `swapCostBps` reads `currentBuyFeeRate(poolId)`, which counts the LP fee and the anti-snipe window. Montra had more than 11,000 coins on November 9, 2026.
- **Boxa's platform cut.** Boxa keeps 30% of the tax before its creator, buyback and holder split, so every share a Boxa coin shows is of the remaining 70%: a coin whose creator share is 30% pays the router 21% of the tax, and a 50% holder share is 35% of it. Boxa's `pools(poolId)` lists the shares as creator, buyback, holders (measured on EPEPE, whose 3000, 2000, 5000 paid the creator 2100 bps of the tax and the holders about 3500), and the adapter reads them in that order.
- **ElysPump's platform cut.** ElysPump keeps 30% of each trade's fee (`PLATFORM_SHARE_BPS`) and splits the rest by the coin's receiver, holders and buyback shares, set at launch and summing to 10000. So a coin with a 1% fee and a 50% receiver share pays the router 0.35% of every trade. The hook credits the receiver's share at every trade and spends the buyback share itself. In the first seconds after launch a coin can charge a higher snipe fee, which `swapCostBps` reads from `currentBuyFeeBps(coin)`. On November 8, 2026, 392 of the 396 coins on the v2 and v3 hooks were quoted in HYPE, and 308 of those paid their fee receiver a share.

## Dividends and the harvest

ElysPump, Boxa and Kleos can pay holders HYPE dividends by balance, and none of them excludes Exile. So Exile earns dividends on every locked coin there. `Exile.harvest(coin)` claims them and notifies them to the coin's reward pool, where they drip to lockers by points like any other payout. The factory sets the harvest when it deploys a router (`setHarvest`, which only a registrar can call and which only accepts the claim shapes Exile knows), and anyone can call `harvest`. Volta's and Montra's factories never set one: Volta leaves contracts out of its holder payouts, and an activated Montra coin pays its holders nothing. So neither needs to be an Exile registrar.

HYPE that reaches Exile outside a harvest is kept per sender and joins the harvest of the coin that sent it. Exile also still accepts a `claimFor(exile)` harvest shape on the coin, which no supported launchpad uses now. On Kleos and Boxa the payer of a dividend claim is the pool manager, so HYPE a holder pushes to Exile there (`claimRewards(exile)` on Kleos, `claimRewards(coin, exile)` on Boxa) is set aside under the pool manager and never harvested; only that holder loses it. On ElysPump `claim()` pays whoever calls it, so only Exile's own harvest can claim Exile's dividends. Harvests themselves are counted whoever pays them.

**Only the harvest pool takes locks of a harvested coin.** A harvest claims the dividends on all of Exile's balance of the coin and pays them to one pool, so a plain time lock or a lock in another pool of the same coin would be earning dividends for that pool's lockers. Once a coin has a harvest, `lockERC20` refuses any lock of it outside the harvest pool (`HarvestPoolOnly`). Locks made before the harvest was set, that is before the router was activated, keep running to their end, and their coins' dividends go to the harvest pool from then on.

A locker who unlocks just before a harvest misses that harvest's dividends, so the keeper harvests on every run. A router upgrade moves the coin's harvest to the new router's pool, and new locks of the coin go there; locks in the old pool keep running to their end. From the upgrade on, the new router pays fees and the harvest pays dividends to the new pool only, so the old pool's lockers earn nothing new after what was already notified has dripped out, until they unlock and lock again in the new pool. That is why a successor factory is meant to keep paying a coin's old pool as well (see SECURITY.md); this factory, used as a successor, would not.

## Buybacks: phase 1 and phase 2

- **Phase 1 (the default).** Routers activate with no swapper, so the 20% buyback share waits in the router's `buybackReserve`. Lockers and the treasury are paid as normal.
- **Phase 2.** A router buys back through `V4Swapper`, one per pool manager, recorded in the deployments file. The steward turns it on with `proposeConfig` (12 hour timelock), or a creator activates with `SWAPPER=v4`, which picks the swapper for the coin's pool manager. On Boxa set it per router: the factory's default can name only one swapper and the uni launcher's hook runs on a pool manager of its own. The reserve then goes out in capped pieces at least 30 minutes apart.
- **The floor counts the tax.** The minimum output is the stricter of a floor at the price observer's 30 minute time-weighted average and one at spot, less the coin's buy tax (`swapCostBps`) and the slippage allowance. The observer (`V4PriceObserver`) records at most one observation per second per pool, so a swap and a buyback in the same transaction can't move the average that prices the buyback; until it has watched a pool for 30 minutes the average is 0 and buybacks wait. `distribute` pokes it first (anyone can poke it too), so the keeper's runs keep it warm; `V4Swapper` only reads the pool key the observer recorded. A buy fee above 11% (`MAX_SWAP_COST_BPS`, for example Volta's anti-snipe fee right after launch) skips the buyback until it drops. Montra's 10% tier stays under it.
- `V4Swapper` swaps exact HYPE in and takes the coins straight to the burn sink, so the router never holds the coin and a max-wallet limit on the coin can't block a buyback.

## Deploying to Elysium mainnet

Deploy only after Elysium's public launch on November 9 (until then transactions go through the HyperEVM inbox), after the audit, and with the multisig in place.

```bash
export RPC_URL=<an Elysium mainnet RPC> PRIVATE_KEY=<the deployer> FACTORY_OWNER=<the Safe>

# 1. The shared core, the adapters with their hooks, a buyback swapper per pool manager and a factory per launchpad
#    (Ascend v5 included: its adapter, an AscendV5Swapper and its factory, see docs/ascend-v5.md).
#    Adds the ElysPump, Boxa and Kleos factories as Exile registrars at once (Exile is still empty, so there is no
#    wait; see below) and hands Exile to FACTORY_OWNER.
#    Writes deployments/launchpads/99901.json. Safe to re-run: it only deploys what the file doesn't record.
forge script contracts/script/DeployLaunchpads.s.sol --rpc-url $RPC_URL --broadcast --slow

# 2. The Safe calls Exile.acceptOwner().

# 3. Activations on every launchpad can start right after step 1. FinishLaunchpads checks that the registrars are
#    in place. It only has work to do if step 1 had to propose them instead (see below): then it adds them 12 hours
#    later (and within 7 days), from any funded key.
forge script contracts/script/FinishLaunchpads.s.sol --rpc-url $RPC_URL --broadcast --slow

# 4. The keeper: set the MAINNET_KEEPER_PRIVATE_KEY secret (a wallet that only holds gas) and the
#    MAINNET_RPC_URL repository variable, and commit deployments/launchpads/99901.json.
```

**Registrars at deploy.** Exile's owner adds a registrar behind a 12 hour timelock, except while Exile is still empty: until the first pool is created or the first lock is made, `addRegistrarWhileEmpty` adds one at once, because no one's coins are inside for the wait to protect. A fresh deploy uses it, so ElysPump, Boxa and Kleos coins can activate as soon as the deploy has run. The first pool or lock closes that path for good. If someone locks something in Exile between its deployment and the registrar transactions, the deploy reverts at that point; run it again and it proposes the registrars instead, and FinishLaunchpads adds them 12 hours later.

`DeployLaunchpads` refuses a `FACTORY_OWNER` without code on chain unless `ALLOW_EOA_OWNER=true`. The file lives in `deployments/launchpads/` rather than `deployments/` because the website reads every `deployments/*.json` as an Ascend deployment; it reads this one separately. Once the file is committed, the site's Lodestar page on Elysium mainnet has the creator pick the launchpad (Ascend first) and paste the coin, checks with that factory's `predict` that the coin really is on it (and names the right launchpad when it isn't), works the router address out from this file rather than trusting the RPC, and walks the creator through that launchpad's activation order; Exile lock transactions go out with 30% gas headroom. To try it on a fork, run the deploy steps of the rehearsal and start the dev server with `VITE_LAUNCHPADS_REHEARSAL=1 VITE_MAINNET_RPC_URL=http://127.0.0.1:8547 VITE_CHAIN_ID=99901`. When the Ascend core reaches mainnet, `DeployCore` reuses this Exile, Sandfall and Lodestar implementation, so every Monarchy router shares one Exile.

**Verify the sources.** elysiumexplore.com answers the Etherscan API shape at `https://elysiumexplore.com/api` (its `getabi` returns verified launchpad contracts), so `forge verify-contract <address> <path>:<Contract> --verifier etherscan --verifier-url https://elysiumexplore.com/api --etherscan-api-key any --chain 99901 --constructor-args <...>` should work; it hasn't been tried yet because nothing is deployed.

**Rehearse first.** `tools/rehearse-ascend-v5.sh` does the same for Ascend v5 on a fork of the latest block (see docs/ascend-v5.md). `ELYSIUM_RPC_URL=https://rpc.eleos.fun tools/rehearse-launchpads.sh` runs the whole rollout on a local anvil fork of mainnet and sends nothing to the real chain: deploy (checking that the three registrars are in place with no wait), finish, the multisig accepting Exile, an activation on each launchpad as the creator (ETF on Volta, MIX on ElysPump's v2 hook, CHUD on Boxa's pairs hook, BULL on Kleos hook A, ELYSA on Montra, which claims what the role brought with it first), a locker locking each coin, trading, and two keeper runs. It checks that every router paid lockers and the treasury, that Exile harvested dividends on the three coins that pay them (MIX, CHUD, BULL), that the phase 2 router (BULL, `SWAPPER=v4`) bought back and burned while the others kept the buyback share in reserve, and that a second keeper run right after doesn't buy back again inside the 30 minute interval.

## The keeper

`tools/keeper-launchpads.sh`, run every 3 hours by the `distribute-mainnet` job in `.github/workflows/distribute.yml`, walks every router the factories have made (`allLodestars`): creators activate without asking anyone, and the keeper serves them all. For each router it:

1. if it doesn't hold its coin's creator role, calls its `acceptCreator()` when a dry run says that goes through (an Ascend v5 activation once Ascend's 48 hour wait is over), and otherwise skips it; it also skips a router whose swapper is neither none nor a swapper from the deployments file (the creator picks the swapper, and the keeper's gas shouldn't run code Monarchy didn't deploy);
2. catches its Exile pool up when it is more than 6 hours behind;
3. calls `distribute()` when there is something to route (at least `MIN_ROUTE_WEI` of the quote claimable on the launchpad or held by the router, on Ascend v5 also the pool's fees not yet paid to its escrow, at least `MIN_ROUTE_TOKENS` of the coin, a parked payout, or a buyback reserve with a swapper once 30 minutes have passed since the last buyback), with one retry if a holder payout was parked. `MIN_ROUTE_WEI` is for 18 decimals and is scaled to a quote with fewer (USDC's 6);
4. calls `Exile.harvest(coin)` when a dry run says it brings in at least `MIN_HARVEST_WEI`, after distribute.

The minimums keep dust from costing a send on every run: a router takes HYPE from anyone, so without them 1 wei would count as work. Amounts below them aren't lost; they wait for a run where there's more. The defaults are 0.001 HYPE for a distribute (`MIN_ROUTE_WEI`, about ten times its gas at Elysium's 0.2 gwei), one whole coin for the token side (`MIN_ROUTE_TOKENS`), and 0.00001 HYPE for a harvest (`MIN_HARVEST_WEI`, about its gas: only trades put dividends there, so the minimum only stops a harvest that costs more than it brings). Each can be changed with a repository variable of the same name prefixed `MAINNET_` (for example `MAINNET_MIN_ROUTE_WEI`), and 1 routes anything.

Every send is dry-run first, refused above `MAX_GAS` (default 4,000,000), sent with 30% headroom over the estimate and checked by its receipt. A failing router is reported and the others still run; the job goes red at the end. Nothing is sent unless the RPC answers chain id 99901. The job is skipped until the key, the RPC variable and the deployments file all exist. Boxa's hooks also have a permissionless `releaseHolderRewards(poolId)`; the fork tests show harvests on all three Boxa hooks work without it, so the keeper doesn't call it.

## Owner powers and the multisig

`FACTORY_OWNER` owns the factories and adapters and is handed Exile. It can:

- add hook generations to an adapter (`addHook`; add-only),
- name a successor factory for upgrades and the default swapper for new activations (each behind its own delay),
- deploy a stranded one-step router for its creator (`rescueDeploy`),
- name the launcher that launches new Ascend v5 coins straight into a router (`setLauncher`, Ascend's factory only),
- propose and remove Exile registrars (adding one waits 12 hours, except while Exile is still empty at deploy).

It can't touch routed fees, locks or streams. Three of those powers need a check by the signers each time, because nothing on chain does it for them:

- **A new registrar.** A registrar can point any coin's harvest at a pool of its own and collect that coin's dividends there, so the only registrars should be the ElysPump, Boxa and Kleos factories. Watch Exile for `RegistrarProposed`: a proposal nobody planned has 12 hours before it can be added, and `removeRegistrar` drops it at once. A `RegistrarAdded` with no proposal before it can only come from the deploy, while Exile was still empty; check that the deploy's ones are exactly the three factories in the deployments file. A check in `setHarvest` on who created the pool wouldn't help, since a hostile registrar could create its own pool.
- **A new launcher.** `deployLaunched` deploys a router for whatever steward and settings the named launcher passes, but only for a coin whose escrow already pays that router's address, which only happens to coins launched with it as recipient. Name only the `AscendV5Launcher` from the deployments file, whose code passes the caller as steward.
- **A rescue deploy.** The settings in `rescueDeploy` calldata (split, swapper, treasury recipient, treasury window, steward) are whatever its author wrote, and nothing the creator signed binds them. Compare them with what the creator asked for, in writing and from the creator's address, before signing.

The plan is a Safe 2-of-2 with one key held by the Ascend launchpad team. **Recommendation: make it 2-of-3 with a cold backup key.** With 2-of-2, losing either key freezes upgrades, new hook generations and rescue deploys for good. Safe 1.3.0 is deployed on Elysium mainnet at its canonical addresses (proxy factory `0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2`).

## Operational notes

- **Max-wallet limits.** Kleos coins can cap any single wallet's balance during a launch window. Exile holds every locker's coins in one balance, so locks of a young coin can hit that cap until the window ends.
- **Gas headroom for locks.** A lock sent with exactly the gas a wallet estimated can run out of gas when its block lands in a later Exile hour bucket than the estimate saw (an earlier rehearsal hit this on a Boxa coin). The keeper adds 30%; the website should add headroom on lock transactions too.
- **Don't vest dividend coins in Sandfall.** Sandfall can't take HYPE, so the dividends a vested ElysPump, Boxa or Kleos coin earns can't be collected by anyone and stay in the launchpad's books for good (they only pay the holder who calls). Volta leaves contracts out of its holder payouts, so a Volta coin in Sandfall just earns nothing. Vest a team allocation of these coins elsewhere, or lock it in the coin's Exile pool. The treasury streams the routers open hold HYPE, not coins, so they aren't affected.
- **A quiet coin's buyback can wait.** The price observer moves only when something pokes it, and `distribute` is the keeper's poke. After a day with no trades, one large trade puts spot far from the average, and the next distribute buys nothing because the floor isn't met. The reserve waits while the average catches up over the next runs and nothing halves, so a "bought nothing" on a quiet coin isn't a fault.
- **Kleos hook C.** Coins on hook C quoted in HYPE with no holder share work. A holder share there is paid in stock tokens through a separate distributor that Exile can't claim from, so those coins can't activate.
- **ElysPump's first launchpad.** ElysPump's v1 launchpad (`0x5afe…6fe3`) puts coins in Uniswap v3 pools against WHYPE and splits a 1% LP fee 50/50 with the creator, with `setCreator(coin, to)` as its hand-over. Monarchy routes Uniswap v4 hooks only, so its 47 coins can't activate yet; supporting it needs a Uniswap v3 adapter and swapper.
- **Not built yet.** The plan's forwarding of Kleos's `lowerTax` (a creator lowering the coin's tax after handing the role over) isn't in this release; a router can't lower its coin's tax.

## Tests

- `forge test` runs the unit suites, including native HYPE routing, one-step handover and both rescues, the harvest shapes and their checks, the harvest pool lock rule, and the v4 pieces on a mock pool manager. The fork suites skip without an RPC.
- `ELYSIUM_RPC_URL=https://rpc.eleos.fun forge test --match-path "contracts/test/fork/*Fork.t.sol"` runs 97 tests (Ascend v5's included) against the real hooks and pool managers on a fork (`ELYSIUM_FORK_BLOCK` pins a block): views, activation in both orders, claim and distribute on every hook kind, the dev's earlier fees staying the dev's, buybacks through `V4Swapper` on every pool manager, harvests on every supported shape, the refusals (lookalike tokens included), the steward handing the role back, and a role sent to another coin's router coming back on Volta, Montra, ElysPump and Kleos.
- `tools/rehearse-launchpads.sh` runs the deploy, activation and keeper scripts end to end on an anvil fork, and `tools/rehearse-ascend-v5.sh` does it for Ascend v5.
