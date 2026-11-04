# Monarchy on Eleos, Kleos and Boxa

**Lock to earn the fees.** Eleos, Kleos and Boxa already split each coin's trading tax between the creator, the holders and a buyback, so another fee splitter adds nothing there. What they don't have is a reason to lock. Monarchy takes the creator's share of the tax and pays it to the holders who lock the coin in Exile, by tier from Peasant (0.5x for a day) to Monarch (4x for a month), with a slice bought back and burned and a slice streamed to the team in the open. Locked coins keep earning the coin's own holder dividends too: Exile claims them and passes them on to the lockers.

All three launchpads are Uniswap v4 hooks on Elysium mainnet (chain 99901). Every coin trades against native HYPE with a 0 LP fee and tick spacing 200, and the tax is taken in HYPE, so a router on these launchpads earns and pays out HYPE. One Lodestar implementation serves them all; what differs per launchpad lives in a small adapter (`contracts/src/sources/`).

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

| | Eleos (eleos.fun) | Kleos (thekleos.xyz) | Boxa (boxa.club) |
|---|---|---|---|
| Hooks the adapter knows | hooks 1, 2, 3 | A and B (single quote), C (multi-quote) | main, pairs, meme pairs, uni launcher |
| Pool manager | `0x5c54…37Da` | `0xb308…2490` | `0x06C6…b2c4`; the uni launcher's hook runs on `0xE2e1…23F1` |
| Handover | one step: `transferCreator(coin, to)` | one step: `transferCreator(coin, to)` | two steps: `proposeCreator(poolId, to)`, then `acceptCreator(poolId)` |
| Who is the creator | `config(coin).creator` on the hook (for bundler launches, not the coin's own `creator()`) | `taxOf(coin).creator` | the pool's creator in `pools(poolId)` |
| How the router is paid | `process(coin)` credits the creator share to the coin's book, `payCreator(coin)` pushes it | `creatorFees(router)`, claimed with `claimCreatorFees()` (hook C: per quote) | `claimable(router)`, claimed with `claim(router)` (later hooks: `claim(0, router)`) |
| Fees earned before the handover | held per coin, so they move with the role: the activation script pays the creator first | held per address, so they stay the creator's | held per address, so they stay the creator's |
| Holder dividends | inside the coin, `claimFor(holder)` (anyone) | inside the coin, `claimRewards(holder)` (the holder) | in the hook, `claimRewards(coin, recipient)` (the holder) |
| Exile harvest | `coin.claimFor(exile)` | `coin.claimRewards(exile)` | `hook.claimRewards(coin, exile)` |
| Not supported | | coins on hook C with a holder share (paid in stock tokens through a separate distributor), coins quoted in anything but HYPE | coins quoted in anything but HYPE |

A coin on a hook the adapter doesn't know reverts with `UnsupportedHook`; a pair quoted in another token reverts with `QuoteUnsupported`. A new hook generation is a config change, not a redeploy: the adapter's owner calls `addHook(hook, kind)`. The registry only grows, and a hook's kind can't change once added.

## Activating a coin

The creator runs `contracts/script/ActivateLaunchpad.s.sol` from the address the launchpad records as the coin's creator. It works out the order from the launchpad, so a creator can't get it backwards.

```bash
export RPC_URL=<an Elysium mainnet RPC>
export PRIVATE_KEY=<the creator's key>
LAUNCHPAD=eleos TOKEN=0xCoin TREASURY=0xTeamTreasury \
  forge script contracts/script/ActivateLaunchpad.s.sol --rpc-url $RPC_URL --broadcast --slow
```

`TREASURY` receives the Team Treasury stream and can never be changed. The rest defaults to MONARCH's settings: 20% buyback and burn / 50% lockers / 30% Team Treasury streamed over 7 days, the Peasant-Knight-Duke-Monarch tiers, and the creator role locked to the router forever. `BURN_BPS`, `HOLDERS_BPS`, `TREASURY_BPS`, `MAX_SLIPPAGE_BPS`, `TREASURY_WINDOW`, `LOCK_FOREVER=false` and `SWAPPER` override them (see `.env.example`).

What the script sends, per launchpad:

- **Boxa (two steps, like Ascend).** `predict(coin, 0)` gives the router address. The creator calls `proposeCreator(poolId, router)` on the coin's hook, then `factory.deploy(params)`, which creates the router, its Exile pool and Sandfall stream, and accepts the role in the same transaction. Nobody else can deploy that router: the factory checks that the caller is the creator and that the predicted router is the one proposed. Fees the creator earned before stay claimable by the creator on Boxa.
- **Eleos (one step).** The hook holds a coin's unpaid creator fees per coin, so they would move with the role. The script first runs `process(coin)` if it is due and `payCreator(coin)`, so the creator keeps what they earned (`CLAIM_FIRST=false` skips this and lets the router route it). Then `factory.deploy(params)`, which checks the caller is the creator, and then `transferCreator(coin, router)` on the hook. The router earns from the moment the role arrives.
- **Kleos (one step).** `factory.deploy(params)`, then `transferCreator(coin, router)` on the hook. Kleos keeps creator fees per address, so fees earned before stay the creator's to claim with `claimCreatorFees()`. Kleos's hooks ask Arbitrum's ArbSys precompile about their caller, which forge's local EVM doesn't have; the script stubs it for its own run, and the broadcast needs `--skip-simulation` so forge doesn't simulate a second time without the stub.

If the second transaction of a one-step activation doesn't land, run the script again: it sees the router and only hands the role over. A router without the role earns nothing and the keeper skips it.

If a creator sent the role to the predicted address before the router existed, nothing on chain proves who sent it, so `deploy` refuses everyone. The script prints the `rescueDeploy(params, steward)` calldata instead; the factory owner checks off chain who sent the role and deploys the router with the creator's settings.

A coin whose holder share Exile can't pass on to lockers is refused at deploy with `HoldersSplitActive` (today only Kleos hook C coins with a holder share).

## Fees

- **The launchpad's own split doesn't change.** The tax rate and the split between creator, holders, buyback and platform were set when the coin launched. The router only ever receives the creator share. For lockers to earn the whole tax that a launchpad pays creators, the coin should launch with its tax going to the creator (Eleos `creatorBps`, Kleos `creatorBps`, Boxa's creator share); a share left to the launchpad's own holder dividends still reaches lockers through the harvest.
- **Routing.** `distribute()` runs the adapter's collect and claim calls (Eleos `process` and `payCreator`, Kleos `claimCreatorFees`, Boxa `claim`) and then splits the router's HYPE balance: lockers through `Exile.notifyReward{value}`, the Team Treasury through `Sandfall.topUp{value}`, buyback through the swapper. HYPE sent to the router any other way is routed the same way. The router only calls its own hook and pays nothing out except to Exile, Sandfall, the swapper and the burn sink.
- **Token side.** These launchpads take no tax in the coin, so the token side is normally 0; any coins the router holds go to lockers (the default) or are burned.

## Dividends and the harvest

All three launchpads can pay holders HYPE dividends by balance, and none of them excludes Exile. So Exile earns dividends on every locked coin. `Exile.harvest(coin)` claims them and notifies them to the coin's reward pool, where they drip to lockers by points like any other payout. The factory sets the harvest when it deploys a router (`setHarvest`, which only a registrar can call and which only accepts the three claim shapes in the table above), and anyone can call `harvest`. HYPE that a third party pushes to Exile (Eleos lets anyone call `claimFor(exile)`) is credited to the coin it came from and joins the next harvest; HYPE from anyone else is kept apart and never harvested.

A locker who unlocks just before a harvest misses that harvest's dividends, so the keeper harvests on every run. A router upgrade moves the coin's harvest to the new router's pool.

## Buybacks: phase 1 and phase 2

- **Phase 1 (the default).** Routers activate with no swapper, so the 20% buyback share waits in the router's `buybackReserve`. Lockers and the treasury are paid as normal.
- **Phase 2.** A router buys back through `V4Swapper`, one per pool manager, recorded in the deployments file. The steward turns it on with `proposeConfig` (12 hour timelock), or a creator activates with `SWAPPER=v4`, which picks the swapper for the coin's pool manager. On Boxa set it per router: the factory's default can name only one swapper and the uni launcher's hook runs on a pool manager of its own. The reserve then goes out in capped pieces at least 30 minutes apart.
- **The floor counts the tax.** The minimum output is the stricter of a floor at the price observer's 30 minute time-weighted average and one at spot, less the coin's buy tax (`swapCostBps`) and the slippage allowance. The observer (`V4PriceObserver`) records at most one observation per second per pool, so a swap and a buyback in the same transaction can't move the average that prices the buyback; until it has watched a pool for 30 minutes the average is 0 and buybacks wait. `distribute` pokes it first (anyone can poke it too), so the keeper's runs keep it warm; `V4Swapper` only reads the pool key the observer recorded. A buy tax above 5% (`MAX_SWAP_COST_BPS`, for example an Eleos anti-snipe surcharge right after launch) skips the buyback until it drops.
- `V4Swapper` swaps exact HYPE in and takes the coins straight to the burn sink, so the router never holds the coin and a max-wallet limit on the coin can't block a buyback.

## Deploying to Elysium mainnet

Deploy only after Elysium's public launch on November 9 (until then transactions go through the HyperEVM inbox), after the audit, and with the multisig in place.

```bash
export RPC_URL=<an Elysium mainnet RPC> PRIVATE_KEY=<the deployer> FACTORY_OWNER=<the Safe>

# 1. The shared core, the adapters with their hooks, a V4Swapper per pool manager and a factory per launchpad.
#    Proposes the three factories as Exile registrars and hands Exile to FACTORY_OWNER.
#    Writes deployments/launchpads/99901.json. Safe to re-run: it only deploys what the file doesn't record.
forge script contracts/script/DeployLaunchpads.s.sol --rpc-url $RPC_URL --broadcast --slow

# 2. The Safe calls Exile.acceptOwner().

# 3. Twelve hours later (and within 7 days), any funded key adds the registrars. Activations can start then.
forge script contracts/script/FinishLaunchpads.s.sol --rpc-url $RPC_URL --broadcast --slow

# 4. The keeper: set the MAINNET_KEEPER_PRIVATE_KEY secret (a wallet that only holds gas) and the
#    MAINNET_RPC_URL repository variable, and commit deployments/launchpads/99901.json.
```

`DeployLaunchpads` refuses a `FACTORY_OWNER` without code on chain unless `ALLOW_EOA_OWNER=true`. The file lives in `deployments/launchpads/` rather than `deployments/` because the website reads every `deployments/*.json` as an Ascend deployment; teaching the site this shape is the website work. When the Ascend core reaches mainnet, `DeployCore` reuses this Exile, Sandfall and Lodestar implementation, so every Monarchy router shares one Exile.

**Verify the sources.** elysiumexplore.com answers the Etherscan API shape at `https://elysiumexplore.com/api` (its `getabi` returns the verified Eleos hook), so `forge verify-contract <address> <path>:<Contract> --verifier etherscan --verifier-url https://elysiumexplore.com/api --etherscan-api-key any --chain 99901 --constructor-args <...>` should work; it hasn't been tried yet because nothing is deployed.

**Rehearse first.** `ELYSIUM_RPC_URL=https://rpc.eleos.fun tools/rehearse-launchpads.sh` runs the whole rollout on a local anvil fork of mainnet and sends nothing to the real chain: deploy, the 12 hour wait, finish, the multisig accepting Exile, an activation on each launchpad as the creator (TST2255 on Eleos, BULL on Kleos hook A, CHUD on Boxa's pairs hook, all with a holder share), a locker locking each coin, trading, and two keeper runs. It checks that every router paid lockers and the treasury, that Exile harvested dividends on all three, that the phase 2 router (BULL, `SWAPPER=v4`) bought back and burned while the others kept the buyback share in reserve, and that a second keeper run right after doesn't buy back again inside the 30 minute interval.

## The keeper

`tools/keeper-launchpads.sh`, run every 3 hours by the `distribute-mainnet` job in `.github/workflows/distribute.yml`, walks every router the three factories have made (`allLodestars`): creators activate without asking anyone, and the keeper serves them all. For each router it:

1. skips it if it doesn't hold its coin's creator role, or if its swapper is neither none nor a V4Swapper from the deployments file (the creator picks the swapper, and the keeper's gas shouldn't run code Monarchy didn't deploy);
2. catches its Exile pool up when it is more than 6 hours behind;
3. calls `distribute()` when there is something to route (fees claimable on the launchpad, a balance, a parked payout, or a buyback reserve with a swapper once 30 minutes have passed since the last buyback), with one retry if a holder payout was parked;
4. calls `Exile.harvest(coin)` when a dry run says it brings HYPE in. This comes after distribute, because on Eleos the `process` inside distribute is what pays the holder share into the coin.

Every send is dry-run first, refused above `MAX_GAS` (default 4,000,000), sent with 30% headroom over the estimate and checked by its receipt. A failing router is reported and the others still run; the job goes red at the end. Nothing is sent unless the RPC answers chain id 99901. The job is skipped until the key, the RPC variable and the deployments file all exist. Boxa's hooks also have a permissionless `releaseHolderRewards(poolId)`; the fork tests show harvests on all three Boxa hooks work without it, so the keeper doesn't call it.

## Owner powers and the multisig

`FACTORY_OWNER` owns the three factories and adapters and is handed Exile. It can:

- add hook generations to an adapter (`addHook`; add-only),
- name a successor factory for upgrades and the default swapper for new activations (each behind its own delay),
- deploy a stranded one-step router for its creator (`rescueDeploy`),
- propose and remove Exile registrars (adding one waits 12 hours).

It can't touch routed fees, locks or streams. The plan is a Safe 2-of-2 with one key held by the Ascend launchpad team. **Recommendation: make it 2-of-3 with a cold backup key.** With 2-of-2, losing either key freezes upgrades, new hook generations and rescue deploys for good. Safe 1.3.0 is deployed on Elysium mainnet at its canonical addresses (proxy factory `0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2`).

## Operational notes

- **Max-wallet limits.** Eleos and Kleos coins can cap any single wallet's balance during a launch window. Exile holds every locker's coins in one balance, so locks of a young coin can hit that cap until the window ends.
- **Gas headroom for locks.** A lock sent with exactly the gas a wallet estimated can run out of gas when its block lands in a later Exile hour bucket than the estimate saw (the rehearsal hit this on Eleos and Boxa coins). The keeper adds 30%; the website should add headroom on lock transactions too.
- **Kleos hook C.** Coins on hook C quoted in HYPE with no holder share work. A holder share there is paid in stock tokens through a separate distributor that Exile can't claim from, so those coins can't activate.
- **Not built yet.** The plan's forwarding of Kleos's and Eleos's `lowerTax` (a creator lowering the coin's tax after handing the role over) isn't in this release; a router can't lower its coin's tax.

## Tests

- `forge test` runs the unit suites, including native HYPE routing, one-step handover and rescue, the harvest shapes and their checks, and the v4 pieces on a mock pool manager. The fork suites skip without an RPC.
- `ELYSIUM_RPC_URL=https://rpc.eleos.fun forge test --match-path "contracts/test/fork/*Fork.t.sol"` runs 27 tests against the real hooks and pool managers on a fork (`ELYSIUM_FORK_BLOCK` pins a block): views, activation in both orders, claim and distribute on every hook kind, the dev's earlier fees staying the dev's, buybacks through `V4Swapper` on all four pool managers, harvests on every supported shape, the refusals, and the steward handing the role back.
- `tools/rehearse-launchpads.sh` runs the deploy, activation and keeper scripts end to end on an anvil fork.
