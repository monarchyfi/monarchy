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

## Design guarantees

See the security model in the [README](README.md#security-model) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
