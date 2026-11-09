# Security

Monarchy is a testnet build for the Ascend x Elysium Builder Competition. It has had five internal security reviews but no third-party audit yet. Don't use it with real funds yet.

## Reporting a vulnerability

Please report security issues privately through GitHub's [private vulnerability reporting](https://github.com/monarchy-fi/monarchy/security/advisories/new) rather than in a public issue. Include the contract, the steps to reproduce and the impact you expect. We'll acknowledge the report and keep you updated while we fix it.

## Scope

- `contracts/src`: Lodestar, LodestarFactory, AscendSwapper, Exile, Sandfall and their libraries, the fee-source adapters in `contracts/src/sources`, V4Swapper and V4PriceObserver
- The deployment scripts in `contracts/script`

Mocks under `contracts/src/mocks` and the website are out of scope for security reports, though bug reports are welcome as issues.

## Reviews

Five internal security reviews have run. Each finding was shown with a proof-of-concept test or a concrete code path. None of them is a third-party audit, which comes before mainnet.

- **October 17, 2026:** a first pass over all five contracts, then two deeper passes covering Lodestar with the factory and swapper, Exile, Sandfall, and the keeper, scripts and site around them. Every finding was fixed, the last of them in [PR #3](https://github.com/monarchy-fi/monarchy/pull/3).
- **October 18, 2026:** a fourth pass over the lock-forever activation, the 7-day upgrade path and token-side rewards to lockers. It found no Critical or High issues. The fixes are in [PR #15](https://github.com/monarchy-fi/monarchy/pull/15), and the contract fixes reach testnet with the next core redeploy:
  - `distribute()` brings Exile up to date first, so it can't run out of gas after a long keeper outage.
  - Exile's `claimRewardTokenTo` pays reward-token rewards even if the stake token is paused.
  - The factory owner is set at deployment and changes hands in two steps.
  - The site says when a forever lock can still move.

  Two Medium findings concern the upgrade path itself and are handled by design. On a live chain the factory owner is a multisig separate from every steward, planned as a 2-of-2 with one key held by the Ascend team. A newer Lodestar must also keep paying the old Exile pool and Team Treasury stream, so an upgrade doesn't leave lockers earning nothing until their locks end.

- **November 4, 2026:** a fifth pass over the Eleos, Kleos and Boxa integration (the fee-source adapters, native HYPE in Lodestar, Exile and Sandfall, the Exile dividend harvest and its registrars, one-step activation and `rescueDeploy`, V4Swapper and V4PriceObserver, and the mainnet scripts and keeper), with proof-of-concept tests on a mainnet fork. It found no Critical, High or Medium issues, four Lows and six Infos. The contract and keeper fixes are in [PR #33](https://github.com/monarchy-fi/monarchy/pull/33):
  - A creator role sent to another coin's router by mistake can be recovered: the factory owner's `rescueDeploy` deploys the coin's router and moves the role into it.
  - Exile only takes locks of a coin with a dividend harvest in that coin's harvest pool, so a plain lock's dividends can't be collected by another pool's lockers.
  - The keeper skips dust below a minimum, so 1 wei sent to a router doesn't cost a send every run.
  - The docs say not to vest launchpad coins in Sandfall (their dividends can't be collected), correct who pays a pushed dividend on Kleos and Boxa, give Boxa's platform cut, and add the registrar and rescue checks to the owner's runbook.

  The fourth Low concerns the website's activation page, which takes the router address from the RPC; its fix belongs with the website support for these launchpads. The integration still needs the third-party audit before mainnet. [docs/launchpads.md](docs/launchpads.md) lists what the factory owner can do and the known limits.

- **November 9, 2026:** a sixth pass over everything added since the fifth: the Volta and Montra adapters, Lodestar's second call target (`payer`, for Volta's separate fee escrow), the ElysPump adapter and Exile's `claim()` harvest, the Ascend v5 launcher and the factory's `deployLaunched`, `Exile.addRegistrarWhileEmpty`, the deploy and activation scripts, the keeper, the picture upload service and the website. The fuzz tests ran 10,000 times each and the invariant suites 1,000 runs deep. It found no Critical or High issues, one Medium, two Lows and four Infos, and no contract had to change:
  - Medium: the picture upload service limited uploads per wallet only, and wallets cost nothing to make, so a script could fill the Pinata plan. It now also caps uploads per connection (20 a day) and in all (300 a day), and refuses to pin without its counter store.
  - Low: the site offered "Launch on Ascend" as soon as the deployments file recorded the launcher, before the multisig names it on the factory (`setLauncher`), when every launch would revert. The tab now waits for the factory to name it.
  - Low: Volta pays its own holder share to wallets only, so a Volta coin locked in Exile stops earning it, and the lock form didn't say so. It does now, for coins whose Volta holder share isn't 0.
  - Infos: on Montra and Ascend v5 a role the router hands out takes the pool's unclaimed fees with it (only when the role isn't locked, or in an upgrade; now in docs/launchpads.md); Volta and ElysPump credit fees by address, so a role sent to the wrong router mixes fees until the rescue (already documented); a lock landing mid-deploy sends the registrars back to the 12 hour route (documented); a wallet's "send NFT" uses `safeTransferFrom`, which a router refuses, so Volta hand-overs go through the site's `transferFrom`.

- **November 9, 2026 (seventh pass):** a review of everything from scratch rather than of what changed: every contract line by line (Exile, Lodestar, the factory, Sandfall, the six adapters, the swappers, the price observer and the launcher), the deploy and activation scripts, the keeper, the picture upload service and every page and component of the website. The unit suite (241 tests), the 87 mainnet fork tests, the fuzz tests at 10,000 runs each and the invariant suites at 1,000 runs 120 calls deep all passed. It found no Critical, High or Medium issues, one Low and five Infos:
  - Low: a router's steward role moved in one step (`transferSteward`), while the factory's and Exile's owner roles move in two, so a mistyped address would have frozen the router's settings for good or handed a stranger the swapper choice. It now moves in two steps: `transferSteward` names the next steward, who takes the role with `acceptSteward`, and naming 0 cancels. The current steward keeps every power until then.
  - Info: after a router upgrade the old Exile pool receives no new fees or dividends (the harvest moves to the new pool too), so lockers there earn nothing new until they lock again in the new pool. The design note from the fourth pass stands, that a successor factory must keep paying the old pool; docs/launchpads.md now says what this factory would do as one.
  - Info: a production build of the site reads Elysium testnet unless `VITE_CHAIN_ID` is set. The Pages workflow now takes the chain and the picture upload URL from repository variables, so the mainnet site is a settings change, and the README says so.
  - Info: the picture upload service checked smart-contract wallet signatures through a third launchpad's RPC; it now uses the public Elysium RPC the site reads. Its signatures stay valid for 15 minutes and pin the same picture to the same link, so a replay changes nothing.
  - Info: the password page's link preview text and footer still described the earlier positioning and the testnet; they match the site now.
  - Info: a comment in the launchpad scripts listed the launchpads in a different order from the constants it describes (the constants were right).

  Also confirmed and left as they are: locks made before a coin's harvest is set earn dividends that go to the harvest pool's lockers (documented in the fifth pass); a hook that pays a creator fee straight to the router during a buyback swap understates that buyback's spend slightly, and the router's accounting stays whole (its reserve never exceeds its balance); a dishonest steward-chosen swapper can keep the margin above the minimum output (documented in docs/ARCHITECTURE.md).

## Design guarantees

See the security model in the [README](README.md#security-model) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
