<div align="center">

<img src="web/public/crown.svg" alt="Monarchy crown" width="88" height="88" />

# Monarchy

### Lock to earn the fees. On Ascend, Eleos, Kleos and Boxa.

[![CI](https://github.com/monarchy-fi/monarchy/actions/workflows/ci.yml/badge.svg)](https://github.com/monarchy-fi/monarchy/actions/workflows/ci.yml)
[![Tests: 234 passing](https://img.shields.io/badge/Foundry-234%20tests%20passing-111111.svg)](contracts/test)
[![Solidity 0.8.28](https://img.shields.io/badge/Solidity-0.8.28-363636.svg)](foundry.toml)
[![Elysium testnet](https://img.shields.io/badge/Elysium%20testnet-chain%2099801-111111.svg)](https://elysium.kinetiq.xyz/testnet-explorer)
[![Protocol fees: none](https://img.shields.io/badge/protocol%20fees-none-111111.svg)](#how-it-works)
[![License: MIT](https://img.shields.io/badge/License-MIT-111111.svg)](LICENSE)

**Holders who lock earn a share of every creator fee, more the longer they lock. Each creator decides how the rest is burned, bought back or streamed to the team, and every change happens in public. Monarchy takes nothing.**

[Website](https://monarchy.fi) · [Docs](https://docs.monarchy.fi) · [X](https://x.com/monarchyfi) · [Architecture](docs/ARCHITECTURE.md) · [Eleos, Kleos and Boxa](docs/launchpads.md) · [Demo script](docs/DEMO.md) · [Testnet contracts](#live-on-elysium-testnet)

<img src="docs/img/site-home.png" alt="The Monarchy home page: four tabs around a crown along the top with the CA chip on the right, the name MONARCHY above a large spinning crown drawn in text characters, and Steal the Crown in gold with the line Lock to earn. The kingdom shares everything with those who stay. below it" width="840" />

</div>

---

## Why Monarchy

Ascend has no token, and its NFT is capped at 500. People who want a piece of Ascend usually reach for the launchpad's own token, and here there isn't one. Monarchy aims to be that token: a liquid coin whose trading fees flow back to the holders who lock it, built on the same tools it offers every other Ascend project.

On Ascend the creator role collects a share of every swap fee: half of a 1% fee on the testnet launchpad, and on Ascend's mainnet launchpad (v5) a fee the creator picks from 1% to 10%, paid in the quote asset. Without Monarchy that money sits in one wallet, holders earn nothing for holding, and promises about buybacks or vesting can't be checked on chain. Monarchy replaces those promises with contracts, built on two ideas:

- **Lock to earn.** Holding a token earns nothing on its own. Holders who lock it in Exile earn a share of every fee, by tier from Peasant (0.5x for a day) to Monarch (4x for a month), so rewards go to the people who stay, not to wallets that sell the next day.
- **Your token, your rules.** Each creator sets the split between buyback and burn, lockers and the Team Treasury, where token-side fees go, the four lock tiers and how fast the treasury streams. Splits, routes and tiers stay adjustable, but only in public: every change waits 12 hours on chain where anyone can see it coming.

### On Ascend's mainnet launchpad (v5)

Ascend v5 gives each coin a creator escrow. A Vanilla coin's creator proposes its Lodestar as the escrow's recipient, and 48 hours later anyone completes the hand-off; from then on every fee the escrow releases is routed. Buybacks run through the coin's own Uniswap v4 pool at any fee Ascend allows. See [docs/ascend-v5.md](docs/ascend-v5.md) for the activation steps, how Ascend's held fees work and what is still to deploy.

### On Eleos, Kleos and Boxa

The Uniswap v4 launchpads on Elysium mainnet already split each coin's tax between the creator, the holders and a buyback, so Monarchy doesn't offer them another split. It gives their holders a reason to lock: the creator hands the coin's creator role to a Lodestar, and the creator's share of the tax, paid in HYPE, goes to the holders who lock the coin in Exile (50% by default, by tier), with 20% bought back and burned and 30% streamed to the team. Locked coins don't give up the coin's own holder dividends either: Exile claims them and passes them on to the lockers. One router design serves all three through a small adapter per launchpad, tested against the real hooks on a mainnet fork. See [docs/launchpads.md](docs/launchpads.md) for the activation guide per launchpad, the fee rules and the mainnet runbook.

## Monarchy runs on Monarchy

The MONARCHY token gets no special treatment. It launches on Ascend like any other token and runs on the same contracts Monarchy offers everyone, with the same zero fees, the same 12 hour timelock and the same 7 day notice before a router can move. Most tokens ask holders to trust the team with the fees; MONARCHY's are handled by code anyone can read and check.

| | How MONARCHY uses it |
|---|---|
| **Lodestar** | Its creator role goes to its own Lodestar, locked there forever. Token-side fees are paid to lockers or burned, and the quote side splits into buyback and burn, holder rewards and the Team Treasury. |
| **Exile** | Holders lock MONARCHY to earn the holder share of every fee, by tier from Peasant to Monarch. |
| **Sandfall** | The Team Treasury share streams to the team in the open, never in one lump. |
| **Garden** | Monarchy's analytics page lists every lock, vesting stream and fee router, MONARCHY's included, live from the contracts at [monarchy.fi/garden](https://monarchy.fi/garden). Locks and streams sit under MONARCHY and Others, every table filters by token address or symbol, and each router shows any change still waiting out its timelock. |

On testnet, Sample Token (SMPL) stands in for MONARCHY with exactly this setup.

## How it works

```mermaid
flowchart LR
    A[Launchpad pool<br/>creator fees] --> L(Lodestar)
    L -->|token side, default| E
    L -->|token side, if chosen| B[Burned]
    L -->|quote, burn share| S[AscendSwapper or V4Swapper] --> B
    L -->|quote, holder share| E[Exile<br/>3 day drip to lockers]
    L -->|quote, treasury share| T[Sandfall<br/>rolling Team Treasury stream]
```

| | What it does |
|---|---|
| **Lodestar** | A fee router for one token on Ascend, or on Eleos, Kleos or Boxa where the quote is native HYPE ([details](docs/launchpads.md)). The creator launches on the launchpad's own site and keeps the dev buy, then hands the token's *creator role* to its Lodestar. Anyone can call `distribute()`, and the team's keeper calls it every 3 hours so fees never pile up into one big payout: token-side fees are all paid to Exile lockers in the token itself (or, if the creator chooses, burned), and quote-side fees split by the creator's percentages into **buyback and burn**, **holder rewards** (Exile) and a **Team Treasury** (streamed through Sandfall). Ascend's listing set-aside stays off, so the creator's whole fee share reaches the router. |
| **Exile** | Locks ERC-20s (including v2 LP), ERC-721s and ERC-1155s. Locks can be extended, never shortened, cancelled or transferred. ERC-20 locks earn holder rewards by tier, paid as a 3 day drip, and stop earning the second they unlock. |
| **Sandfall** | Vesting streams (linear, with an optional cliff, or in daily, weekly or monthly steps) in any non-rebasing ERC-20 or native HYPE, each with a chart of what unlocks by when. The creator decides at creation whether a stream can be cancelled, and the site badges it. Rolling streams back Lodestar's Team Treasury. |

### Exile tiers

| Tier | Lock | Multiplier | |
|---|---|---|---|
| Peasant | 1 day | 0.5x | *Everyone starts somewhere.* |
| Knight | 3 days | 1x | *Sworn to the kingdom.* |
| Duke | 7 days | 2x | *Next in line.* |
| Monarch | 1 month | 4x | *Steal the crown.* |

No lock, no rewards. With four holders each locking 10,000 tokens and fees dripping at 100 USDC a day, holders who keep re-locking for 30 days earn 200, 400, 800 and 1,600 USDC respectively: each tier earns twice the one below it.

## Security model

- **No upgrades.** Each Lodestar is an EIP-1167 clone of a fixed implementation. Nobody can change its code.
- **No sweep.** There is no rescue or withdraw function. Funds can only go to the burn address, Exile, Sandfall or the swapper. Locked tokens and vesting streams can only go to their owners.
- **Slow changes.** Split, swapper and slippage changes, and Exile tier changes, wait behind a 12 hour timelock and expire if not executed within 7 days after it. Anyone can carry a change out once the wait ends, the steward can cancel it before then, and a new proposal restarts the wait. The token's Lodestar page and the Garden show every pending change with its countdown. Settings chosen at activation apply immediately.
- **Locked router.** At activation the creator can lock the creator role to the Lodestar forever (the default on the site and in the activation script), so the router can't be swapped out; without it, the steward can lock it later. Even locked, it can move to the same token's router on a newer Monarchy factory: the factory owner names that factory, the steward proposes the move, and anyone can carry it out after 7 days' notice. On a live chain the factory owner is a multisig, separate from every steward, so no single key can start a move; the deploy script refuses a plain wallet there. For mainnet the plan is a 2-of-2 with one key held by the Ascend team. On testnet the owner is still the deploy wallet. A different successor named meanwhile stops it. A lock can't be placed while a hand-off is pending.
- **Guarded buybacks.** The minimum output is the stricter of a floor at Ascend's on-chain EMA price (on Eleos, Kleos and Boxa, Monarchy's own 30 minute time-weighted average) and one at spot, less the pool fee or the coin's buy tax and a slippage allowance (default 10%, min 1%, max 20%); spot alone is never trusted. Each buy spends at most 0.5% of the pool's quote depth (and waits while the pool has no active liquidity to measure), so it moves the price less than a sandwich pays in fees, and buys are at least 30 minutes apart, so calling `distribute` many times in one block can't push the whole reserve through between a buy and a sell. Bigger amounts and skipped buys wait in reserve and go out in pieces; holders and treasury are still paid. Every buyback must actually deliver its minimum to the burn address. The swapper is chosen by the steward behind the timelock, and a dishonest one could keep the margin above that minimum, so swapper changes are worth watching.
- **Front-run safe activation.** Only the pool's current creator can deploy its Lodestar, at an address derived from the pool id. On the one-step launchpads (Eleos, Kleos) the creator deploys first and hands the role over after; a role sent to the address before the router existed, or to another coin's router by mistake, can only be finished by the factory owner (`rescueDeploy`).
- **Launchpad adapters.** Everything launchpad specific sits in a stateless adapter that only answers views and lists calls; the router sends those calls itself, only to its own hook, with no value. A coin names its own hook, and the adapter only accepts hooks its owner (the multisig) registered; the registry only grows. Exile's dividend harvest only takes three fixed claim shapes, set by the factory at activation.
- **Fuzz and invariant tested.** Random sequences of locks, payouts, claims, top-ups, cancels, fees and failed buybacks check that Exile stays solvent and never pays out more than it received, that every Sandfall stream stays fully backed, and that every unit of quote a Lodestar handles ends up burned, locked, streamed or held in its buyback reserve.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design and [SECURITY.md](SECURITY.md) for the security reviews and how to report an issue. The contracts have had four internal security reviews but no third-party audit yet.

## Live on Elysium testnet

Sample Token (SMPL) is launched on Ascend's live testnet launchpad with MONARCHY's planned settings: a 20/50/30 split of quote fees between buyback and burn, holders and the Team Treasury, token-side fees paid to Exile lockers, and the 0.5x/1x/2x/4x tiers. Its creator role is held by a Lodestar and locked to it forever. Every feature has been exercised on chain through the real PancakeSwap Infinity pool: an EMA-guarded buyback and burn, holder rewards in both the quote and the token dripping to Exile locks at all four tiers, the Team Treasury stream, lock extension, a config change held by its 12 hour timelock, and a creator role that refuses to move except through the 7 day upgrade path. A second token, Sample Stock Token (SMPLS), is quoted in a mock stock token and burns its token-side fees instead, so both routes are live; its buyback, holder rewards and treasury run in the stock token. Contract sources are verified on the explorer.

| Contract | Address |
|---|---|
| LodestarFactory | [`0x5BAF464E44d395FFCFCA8b8b254686772F038d57`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x5BAF464E44d395FFCFCA8b8b254686772F038d57) |
| Lodestar implementation | [`0x42c65E78f98C5Fe08c4ab1BcdD16f091347Af627`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x42c65E78f98C5Fe08c4ab1BcdD16f091347Af627) |
| Exile | [`0x6B798DBD934eFA0350fc0A0964EdE5E7F369d013`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x6B798DBD934eFA0350fc0A0964EdE5E7F369d013) |
| Sandfall | [`0xCf7080960BB9E9e02a71a8264dB07380Fe7dE844`](https://elysium.kinetiq.xyz/testnet-explorer/address/0xCf7080960BB9E9e02a71a8264dB07380Fe7dE844) |
| AscendSwapper | [`0xE993233316565bBC12F5397d6705446162FC5894`](https://elysium.kinetiq.xyz/testnet-explorer/address/0xE993233316565bBC12F5397d6705446162FC5894) |
| Sample Token (SMPL) | [`0x99095be831E48a9D32340577ED6937B5CE4918BB`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x99095be831E48a9D32340577ED6937B5CE4918BB) |
| SMPL Lodestar | [`0x94FBB86DC8F17cED9821e421039b385Ac7Ea296e`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x94FBB86DC8F17cED9821e421039b385Ac7Ea296e) |
| Sample Stock Token (SMPLS, quoted in a mock stock token) | [`0x463f6EBC7D9C3A303877151c4B213871d68B79FB`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x463f6EBC7D9C3A303877151c4B213871d68B79FB) |
| SMPLS Lodestar | [`0x63E050E43758826244DC49cF134b461f208B57d2`](https://elysium.kinetiq.xyz/testnet-explorer/address/0x63E050E43758826244DC49cF134b461f208B57d2) |

<details>
<summary>Ascend addresses used</summary>

| | |
|---|---|
| AscendLaunchpad | `0x6d01f6644bbf1b5074472D3e85aa1465B4d2bF3d` |
| ListingDesk | `0x06DbB5eF794BA3C0F6F0ddC6164617Cf21811a77` |
| PancakeSwap Infinity CLPoolManager | `0x12E84206cB53aE0df055482ebc4658635096E1aA` |
| Infinity Vault | `0x2B738A9A69b7a45C9dA6B519f6bE6efBfb912aec` |
| Mock USDC (quote) | `0x84Cc00D13173f7016Bbab22A736dBf75A154cFE2` |
| Mock stock token (SMPLS quote) | `0xa7CDbE6342A2eF5f789BCdd3653c7f48c7F16A51` |

</details>

## Repository layout

```
contracts/src        Lodestar, LodestarFactory, AscendSwapper, Exile, Sandfall, V4Swapper, V4PriceObserver,
                     sources/ (the Ascend, Eleos, Kleos and Boxa adapters), interfaces, mocks
contracts/test       Foundry tests, including a full mock-Ascend integration test and fork/ (the real
                     Eleos, Kleos and Boxa hooks on an Elysium mainnet fork)
contracts/script     DeployMocks, DeployCore, LaunchOnAscend, ActivateLodestar, DemoFlow; for Eleos, Kleos
                     and Boxa: DeployLaunchpads, FinishLaunchpads, ActivateLaunchpad
deployments/         <chainId>.json written by the scripts and read by the website; launchpads/<chainId>.json
                     for Eleos, Kleos and Boxa
web/                 Vite + React + wagmi site (landing page, Kingdom overview, Lodestar, Exile, Sandfall)
docs/                Architecture notes, the Eleos, Kleos and Boxa guide, and the demo script
tools/               demo-local.sh, keeper scripts, rehearse-launchpads.sh, export-abis.mjs, offline solc shim
```

## Quickstart

Needs Node 20+ and [Foundry](https://getfoundry.sh) (`curl -L https://foundry.paradigm.xyz | bash && foundryup`).

```bash
git clone --recursive https://github.com/monarchy-fi/monarchy && cd monarchy
npm install
forge test            # or: npm test
```

In a sandbox that can't download solc, use `FOUNDRY_PROFILE=offline` (wraps the solc npm package).

### Run the demo locally (one command)

```bash
npm run demo:local    # anvil + mock Ascend + Monarchy + a demo launch + Lodestar + demo data
npm --prefix web install
npm run web           # http://localhost:5173
```

Point MetaMask or Rabby at `http://127.0.0.1:8545` (chain 31337) and import anvil's first account to act as the creator. On a dev server, `http://localhost:5173/?mock` connects that account without a browser wallet.

The dev server reads the local chain when `deployments/31337.json` exists; a production build always reads Elysium testnet. Set `VITE_CHAIN_ID` to override either.

### The website deploy

The site at monarchy.fi is password protected. The Pages workflow builds the app into one self-contained HTML file, encrypts it with [staticrypt](https://github.com/robinmoisson/staticrypt) using the `SITE_PASSWORD` Actions secret, and serves the same password page as `404.html` so deep links work. The workflow fails if the secret is missing. To try it locally with a throwaway password:

```bash
cd web
SITE_PASSWORD='any-test-password' npm run build:gated   # writes dist/index.html and dist/404.html
```

### Deploy to Elysium testnet

Use a **fresh burner wallet**, never your main wallet. Get testnet HYPE from the [Elysium faucet](https://elysium.kinetiq.xyz/testnet-faucet).

```bash
cp .env.example .env     # set PRIVATE_KEY (the burner), keep the Ascend addresses as they are
set -a; source .env; set +a

# 1. Monarchy core: Exile, Sandfall, Lodestar implementation, AscendSwapper, LodestarFactory.
#    The script refuses to replace a core that deployments/99801.json already records (this repo
#    ships the live testnet one), so a fresh deploy from a clone needs OVERWRITE_DEPLOYMENT=1.
OVERWRITE_DEPLOYMENT=1 npm run deploy:testnet   # writes deployments/99801.json

# 2. A token on Ascend. Either launch on Ascend's site and record it:
TOKEN=0xYourToken npm run launch:testnet
#    or launch from the script (simulate first, then add --broadcast):
npm run launch:testnet
npm run launch:testnet -- --broadcast

# 3. Hand the creator role to the token's Lodestar and activate it (50% holders, 20% buyback,
#    30% treasury, token-side fees to lockers, the four tiers, 7 day treasury stream, no listing
#    set-aside, creator role locked forever).
#    TREASURY is the address that receives the Team Treasury stream; it can never be changed.
#    Buybacks go through the AscendSwapper from deployments/99801.json unless SWAPPER is set.
TREASURY=0xYourTreasury npm run activate:testnet

# 4. The website reads deployments/99801.json
npm run abis && npm run web
```

Mock USDC on Elysium has a public `mint`, so you can fund wallets for trading with
`cast send $QUOTE "mint(address,uint256)" $YOUR_ADDRESS 1000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY`.

If buybacks through the Infinity vault misbehave, Lodestar keeps the buyback share in `buybackReserve` and still pays holders and the treasury. To activate with no buyback route at all, have the factory owner run `setDefaultSwapper(0x0)` at least 12 hours before step 3 (a new default only applies after 12 hours), then run step 3 with `SWAPPER=0x0000000000000000000000000000000000000000`, which asks for the factory's default instead of the deployed AscendSwapper.

The keeper (`.github/workflows/distribute.yml`) calls `distribute()` every 3 hours from a wallet that holds only gas money, set as the `KEEPER_PRIVATE_KEY` Actions secret. Each run checks that `RPC_URL` serves chain 99801, lets `cast` estimate the gas, and fails when the receipt shows a revert, so a broken distribute is a red run rather than a green one. When Exile's reward pool is more than 6 hours behind (after an outage), the run first catches it up with `poke`, one call's worth of hours at a time, so the payouts inside `distribute()` stay light. If `distribute()` fails or a holder payout is parked, it catches up again and tries once more.

### Eleos, Kleos and Boxa on Elysium mainnet

`DeployLaunchpads`, then `FinishLaunchpads` 12 hours later, deploy the shared core, an adapter, a V4Swapper per pool manager and a factory per launchpad; creators activate with `ActivateLaunchpad`, and `tools/keeper-launchpads.sh` keeps every router distributing and harvesting. `tools/rehearse-launchpads.sh` runs all of it on a local fork first. The steps, the owner's powers and the per-launchpad details are in [docs/launchpads.md](docs/launchpads.md).

## Status and roadmap

| | |
|---|---|
| **Working** | Lodestar, Exile and Sandfall live on Elysium testnet with two demo tokens (USDC and stock quotes); burns, buybacks and token rewards to lockers proven on Ascend's pools; web app for all three at monarchy.fi, with the Garden, an analytics page listing every lock, stream and router; docs at docs.monarchy.fi; CI on every change |
| **Built, not deployed** | Eleos, Kleos and Boxa support: native HYPE routing, a dividend harvest in Exile, Uniswap v4 buybacks, and mainnet deploy, activation and keeper scripts, tested against the real launchpads on a mainnet fork and rehearsed end to end on a local one |
| **In progress** | A testnet redeploy with the latest security review fixes |
| **Before launch** | Third-party security audit, the upgrade multisig shared with the Ascend team, mainnet deploy (Eleos, Kleos and Boxa after Elysium's public launch on November 9), Monarchy token launch on Ascend |
| **Next** | Website support for Eleos, Kleos and Boxa coins, kHYPE treasury option, TWAP buybacks, Ascend NFT holder bonus in Exile, an indexer for history and APR charts |

Everything works with Ascend as it is today: a creator launches, then hands over the creator role in two steps. An option on Ascend's launch form to pick a Lodestar up front would make it one step.

## License

[MIT](LICENSE)
