# Monarchy on Ascend v5 (Elysium mainnet)

Ascend's mainnet launchpad is a new contract generation ("v5") on Elysium mainnet (chain 99901). It differs from the
testnet launchpad Monarchy was first built on, so it has its own adapter (`AscendV5FeeSource`) and buyback swapper
(`AscendV5Swapper`). Addresses and rules below were read from Ascend's
[technical docs](https://ascendlaunch.xyz/technical-docs), [contract registry](https://ascendlaunch.xyz/contracts.json)
and the chain on November 5, 2026.

| Contract | Address |
| --- | --- |
| Launchpad (every launch pool's hook) | `0xe0dEF4221b9840a610D4e7d55812a79A6431a8eC` |
| EscrowFactory | `0x63f6a8A8d0257c0363251a50cdE8A8b1046e4d19` |
| PoolManager (Uniswap v4) | `0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1` |
| BurnSink (Ascend's burn address) | `0x9F0b0e3B362937b07Cd1E869b50687961e0c7741` |
| WHYPE / USDC / KNTQ (quote assets) | `0xbA87…5E81` / `0xb47c…0B65` / `0xe45a…acF0` |

## What changed from the testnet launchpad

- **Fees.** The creator picks a fee from 1% to 10% at launch, fixed for life, plus up to 1% for an approved builder.
  Everything above 1% goes to the creator side. Fees are paid in the quote asset only: there is no token-side fee,
  so a v5 router's token-side route stays idle.
- **Held fees.** Below a $40k moving-average market cap only 10% of the fee is paid out as trades happen; the rest is
  held until the coin's average stays above $40k for an hour within 14 days, and forfeited if it doesn't (or if the
  coin goes quiet). The router simply routes what the escrow pays it.
- **The creator role is an escrow.** Each pool has its own `CreatorEscrow`. What a Lodestar takes over is the
  escrow's `recipient`, and a new recipient can accept only 48 hours after it was proposed.
- **Coin types.** Only Vanilla coins can move to Lodestar. Holder Rewards, Buyback and Custom mix coins pay Ascend's
  own seat contract, whose split is fixed at launch.

## Activating a coin

1. The coin's recipient (the creator's wallet) calls `escrow.proposeRecipient(router)`, with the router address
   from `LodestarFactory.predict(token, quote)`. The escrow is `EscrowFactory.escrowOf(poolId)`.
2. The same wallet calls `LodestarFactory.deploy(...)`. The router is deployed with the hand-off still pending
   (`Handover.TwoStepDelayed`); a creator lock asked for here is already set.
3. After 48 hours, anyone calls `Lodestar.acceptCreator()`. From then on the escrow pays the router.

Credits already paid out to the creator before step 3 stay theirs (claim them with `escrow.claim(wallet)`).
Fees still held below the graduation line are not: the escrow pays them to whoever is the recipient when the coin
graduates, so after step 3 that is the router. Quote assets are ERC-20s: a HYPE pair is quoted in WHYPE.

A creator lock set in step 2 only binds once step 3 has happened; until then the creator can cancel the proposal.
`Lodestar.creatorRoleLocked()` is true only while the router holds the role and the lock runs.

### Community takeovers

Most v5 launches (366 of 575 as of November 5, 2026) opted in to Ascend's community takeovers. On those pools
Ascend's `CtoRegistryV5` can replace the escrow's recipient: anyone files a request, Ascend's owner approves it, and
after a 48 hour notice the applicant becomes the recipient. This works on a router too, creator lock or not: the lock
only stops the steward. Credits the router already earned stay claimable and are still routed, but held fees and
all future fees go to the new recipient. `AscendV5FeeSource.takeoverRegistry(poolId)` returns the registry, or zero
when the pool did not opt in, so the site can show this next to the lock.

## Routing and buybacks

`distribute()` first calls the adapter's `poke`, which sends the launchpad's permissionless `collect` and `claim` so
the pool's fees reach its escrow, then claims the router's credit from the escrow and splits it as usual.

**Send distributes with at least 2,000,000 gas.** The escrow's `claim` refuses to run with less than about 600,000
gas left (`InsufficientCollectGas`), and `distribute` carries on without the payout (`ClaimFailed`) rather than
revert. A wallet's or `cast`'s gas estimate finds that cheaper path, so a distribute sent at the estimate routes
nothing. Nothing is lost (the credit waits for the next distribute), but the keeper and the site's Distribute button
send Ascend distributes with a 2,000,000 gas floor, and the keeper warns on a `ClaimFailed` it still sees.
`test_distributeNeedsGasForTheEscrowPayout` shows both paths on a fork.

Buybacks go through `AscendV5Swapper`, which rebuilds the pool key from the pool's escrow and swaps exact quote in
through the launch pool, coins straight to Ascend's BurnSink (v5 coins refuse `0x…dEaD`). The swap cost the floor
allows for is the pool's own `currentFee`. Lodestar now tries buybacks on pools costing up to 11% (it was 5%), so
every v5 fee level, builder fee included, gets its buyback. The limit is shared by every launchpad, so Boxa, Kleos
and Eleos buybacks now also go through at a buy tax of up to 11%. Ascend's EMA only moves on swaps, so after a sharp move
the floor skips buybacks until trading brings the average back in line.

## Tests

`contracts/test/fork/AscendV5Fork.t.sol` runs against the real launchpad, escrows and pools on a mainnet fork, with
Vanilla coins at 1%, 3% and 10% fees and both token orders:

```sh
ELYSIUM_RPC_URL=https://rpc-live.boxa.club forge test --match-contract AscendV5ForkTest
```

## Deploying and running it

Ascend v5 is the fourth launchpad in the mainnet scripts (`LAUNCHPAD=ascend`), so it shares the multisig owner,
Exile, Sandfall and the Lodestar implementation with Eleos, Kleos and Boxa (docs/launchpads.md):

- `DeployLaunchpads` deploys `AscendV5FeeSource`, an `AscendV5Swapper` and a factory, and records them under
  `launchpads.ascend` in `deployments/launchpads/99901.json`. The factory never needs to be an Exile registrar
  (v5 coins pay no holder dividends), so v5 activations can start as soon as it has run.
- `ActivateLaunchpad` with `LAUNCHPAD=ascend TOKEN=<coin>` (and `QUOTE=whype|usdc|kntq` if the script can't tell)
  proposes the router on the escrow and deploys it; run again after the 48 hours, by anyone, it accepts.
- `tools/keeper-launchpads.sh` sends `acceptCreator()` for any router whose wait is over, then keeps it
  distributing. It counts the pool's fees that haven't reached the escrow yet as work, since `distribute` collects
  them first, and scales its minimum to the quote's decimals.
- `ELYSIUM_RPC_URL=https://rpc-live.boxa.club tools/rehearse-ascend-v5.sh` runs all of it on an anvil fork of the
  latest block, with a live 3% Vanilla coin: deploy, activation, a keeper run during the wait that leaves the router
  alone, and the keeper accepting and routing WHYPE to lockers, the treasury and the buyback afterwards.

On the website's Lodestar page (Elysium mainnet), a pasted v5 coin is found against WHYPE, USDC and KNTQ. The page
shows the pool's fee, the escrow, fees Ascend still holds and their graduation deadline, warns when the pool opted in
to community takeovers, and refuses Holder Rewards, Buyback and Custom mix coins (their recipient is Ascend's seat
contract). The steps are the three above, with a countdown to the end of Ascend's wait, an "Accept the creator
role" button anyone can press, and a way for the creator to call the hand-off off before then. A router that is
waiting shows "Lock starts when the router holds the role" rather than a lock that doesn't bind yet.

## Not done yet

- Nothing is deployed: `DeployLaunchpads` needs the multisig and a funded deployer, then the deployments file
  committed so the site and keeper pick it up.
