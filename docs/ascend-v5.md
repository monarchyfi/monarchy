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

Credits the creator earned before step 3 stay theirs. Quote assets are ERC-20s: a HYPE pair is quoted in WHYPE.

## Routing and buybacks

`distribute()` first calls the adapter's `poke`, which sends the launchpad's permissionless `collect` and `claim` so
the pool's fees reach its escrow, then claims the router's credit from the escrow and splits it as usual.

Buybacks go through `AscendV5Swapper`, which rebuilds the pool key from the pool's escrow and swaps exact quote in
through the launch pool, coins straight to Ascend's BurnSink (v5 coins refuse `0x…dEaD`). The swap cost the floor
allows for is the pool's own `currentFee`. Lodestar now tries buybacks on pools costing up to 11% (it was 5%), so
every v5 fee level, builder fee included, gets its buyback. Ascend's EMA only moves on swaps, so after a sharp move
the floor skips buybacks until trading brings the average back in line.

## Tests

`contracts/test/fork/AscendV5Fork.t.sol` runs against the real launchpad, escrows and pools on a mainnet fork, with
Vanilla coins at 1%, 3% and 10% fees and both token orders:

```sh
ELYSIUM_RPC_URL=https://rpc-live.boxa.club forge test --match-contract AscendV5ForkTest
```

## Not done yet

- No deployment script or `deployments/` record for Ascend v5; the factory, adapter and swapper still need
  deploying, with the same multisig owner and shared core as the other mainnet launchpads.
- The website still serves the testnet deployment. Mainnet needs the chain, a v5 deployment file, and an activation
  flow with the 48 hour wait and an "accept" button.
