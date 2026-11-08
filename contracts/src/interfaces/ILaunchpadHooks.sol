// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4PoolKey} from "./IUniswapV4.sol";

/// @notice Eleos's hook (verified source on elysiumexplore.com, hook 3 at 0x8680…6acC): the subset Monarchy uses.
interface IEleosHook {
    struct Config {
        address creator;
        uint16 buyBps;
        uint16 sellBps;
        uint16 creatorBps; // the split of the tax after the platform share, sums to 10000
        uint16 holdersBps;
        uint16 buybackBps;
        uint16 lpBps;
        uint32 snipeSecs;
    }

    struct Book {
        uint64 launchedAt;
        int24 startTick;
        int24 emaTick;
        uint64 emaAt;
        uint128 pending;
        uint128 snipePending;
        uint128 lpHype;
        uint128 lpTokens;
        uint128 creatorOwed;
    }

    function poolManager() external view returns (address);
    function platformBps() external view returns (uint16);
    function keyFor(address token) external view returns (V4PoolKey memory);
    function poolIdOf(address token) external view returns (bytes32);
    function config(address token) external view returns (Config memory);
    function book(address token) external view returns (Book memory);
    function taxNow(address token) external view returns (uint256 buyBps, uint256 sellBps);
    function processable(address token)
        external
        view
        returns (bool ok, uint256 total, int24 tick, int24 average);
    function process(address token) external returns (uint256 total);
    function payCreator(address token) external returns (uint256 amount);
    function transferCreator(address token, address to) external;
}

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
