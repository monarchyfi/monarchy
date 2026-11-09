// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4PoolKey} from "./IUniswapV4.sol";

/// @notice Kleos's hooks (unverified; names from selector lookups, shapes from eth_call on Elysium mainnet).
/// Hooks A and B pay creator fees in native HYPE only; hook C is multi-quote and keys fees by quote.
interface IKleosHook {
    struct Tax {
        address token;
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        uint16 platformBps;
        uint16 creatorBps;
        uint16 holdersBps;
        uint16 buybackBps;
    }

    function poolManager() external view returns (address);
    function taxOf(address token) external view returns (Tax memory);
    function poolKeyOf(address token) external view returns (V4PoolKey memory);
    function creatorFees(address creator) external view returns (uint256); // hooks A, B
    function creatorFees(address creator, address quote) external view returns (uint256); // hook C
    function claimCreatorFees() external; // hooks A, B: pays the caller
    function claimCreatorFees(address quote) external; // hook C: pays the caller
    function transferCreator(address token, address newCreator) external;
}

/// @notice Boxa's hooks (unverified; ABIs from Boxa's site code, checked by eth_call and fork simulation on Elysium
/// mainnet). The main hook keys creator fees by payee only; the pairs, meme-pairs and uni hooks also by currency,
/// with the arguments in a different order on the uni hook. `pools(poolId)` returns a different tuple per
/// generation, so the adapter reads it word by word.
interface IBoxaHook {
    function poolManager() external view returns (address);
    function poolOf(address token) external view returns (bytes32);
    function claimable(address payee) external view returns (uint256); // main hook
    function claimable(address a, address b) external view returns (uint256); // pairs (pair, payee); uni (payee, currency)
    function feePips(bytes32 poolId) external view returns (uint24 buyFeePips, uint24 sellFeePips); // uni hook
    function claim(address recipient) external; // main hook: pays the caller's fees to `recipient`
    function claim(address currency, address recipient) external; // later hooks
    function claimRewards(address token, address recipient) external; // holder dividends, paid to `recipient`
    function proposeCreator(bytes32 poolId, address next) external;
    function acceptCreator(bytes32 poolId) external;
}

/// @notice ElysPump's v2 and v3 hooks (elysp.com; unverified, names from the selector table in ElysPump's own site,
/// shapes from eth_call and fork simulation on Elysium mainnet). Both hooks run the same bytecode, v2 on ElysPump's
/// own pool manager and v3 on the official one. `launches(token)` returns a 13-word tuple the adapter reads word by
/// word: creator, feeReceiver, quote, buyFeeBps, sellFeeBps, receiverShareBps, holdersShareBps, buybackShareBps,
/// snipeFeeBps, launchedAt, snipeSecs, (unused), startTick.
interface IElysPumpHook {
    function poolManager() external view returns (address);
    function keyOf(address token) external view returns (V4PoolKey memory);
    function tokenOfPool(bytes32 poolId) external view returns (address);
    function currentBuyFeeBps(address token) external view returns (uint256);
    function owed(address account, address currency) external view returns (uint256); // across all its coins
    function claim(address currency) external; // pays the caller what it is owed in `currency`
    function setFeeReceiver(address token, address to) external; // only the current receiver, at once
    function flush(address token) external;
    function holderPending(address token) external view returns (uint256);
    function buybackPending(address token) external view returns (uint256);
}

/// @notice Volta's PositionManager (volta.family), the Uniswap v4 hook of every Volta pool, a fork of Flaunch's. ABIs
/// published by Volta at volta.family/abi/volta.json. A coin's creator role is an NFT, its fee shares are fixed at
/// launch, and the creator's share is credited, as fees are distributed, to whoever holds the NFT then, in the
/// pool's fee escrow.
interface IVoltaPositionManager {
    struct CreatorSplit {
        uint24 creator;
        uint24 buyback;
        uint24 holders;
    }

    struct PoolFees {
        uint24 swapFee; // bps
        uint24 antiSnipeStartFee;
        uint32 antiSnipeDuration;
        uint64 tradingOpensAt;
        CreatorSplit creatorSplit; // bps of the creator side (the 70% left after the protocol's 30%)
    }

    function poolManager() external view returns (address);
    function flaunchContract() external view returns (address); // the creator NFT
    function poolKey(address token) external view returns (V4PoolKey memory);
    function poolFees(bytes32 poolId) external view returns (PoolFees memory);
    function currentSwapFee(bytes32 poolId, bool isBuy) external view returns (uint24); // bps
    function pairedTokenFeeEscrow(bytes32 poolId) external view returns (address);
}

/// @notice Volta's creator NFT: one token per launch, an ERC-721 whose holder is the coin's creator.
interface IVoltaCreatorNFT {
    function positionManager() external view returns (address);
    function tokenId(address memecoin) external view returns (uint256);
    function memecoin(uint256 tokenId) external view returns (address);
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Volta's fee escrow: creator fees by recipient and currency, across every coin the recipient has held the
/// NFT of. `withdrawFees` pays the caller's balance to `recipient` (native HYPE whether or not `unwrap`).
interface IVoltaFeeEscrow {
    function balances(address recipient, address token) external view returns (uint256);
    function withdrawFees(address token, address recipient, bool unwrap) external;
}

/// @notice Volta's coin: `flaunch()` names the creator NFT contract, `creator()` its current holder.
interface IVoltaToken {
    function flaunch() external view returns (address);
    function creator() external view returns (address);
}

/// @notice Montra's LaunchHook (montramarkets.xyz), the Uniswap v4 hook of every Montra pool. ABIs published by
/// Montra at montramarkets.xyz/docs/abis.json. Each pool pays its creator side to one recipient (a wallet, a
/// splitter or the coin's holders), who claims whenever they like and hands the stream on in one call, unclaimed
/// fees included. Fee rates are in pips (1,000,000 = 100%).
interface IMontraHook {
    function poolManager() external view returns (address);
    function poolKey(bytes32 poolId) external view returns (V4PoolKey memory);
    function quoteOf(bytes32 poolId) external view returns (address);
    function recipientOf(bytes32 poolId) external view returns (address);
    function tab(bytes32 poolId) external view returns (uint256); // swept, waiting for the recipient
    function pendingCreator(bytes32 poolId) external view returns (uint256); // what a sweep would add
    function currentBuyFeeRate(bytes32 poolId) external view returns (uint256); // pips, all in
    function claim(bytes32 poolId, address to) external returns (uint256); // the recipient only; sweeps first
    function updateRecipient(bytes32 poolId, address newRecipient) external; // the recipient only, at once
}

/// @notice Montra's coin: its pool and hook.
interface IMontraToken {
    function poolId() external view returns (bytes32);
    function hook() external view returns (address);
}
