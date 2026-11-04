// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IV4PoolManager, V4PoolKey} from "./interfaces/IUniswapV4.sol";
import {V4State} from "./libraries/V4State.sol";

/// @title V4PriceObserver
/// @notice A reference price for Uniswap v4 pools that publish none of their own (Boxa and Kleos hooks keep no
/// readable average), for Lodestar's buyback floor. One contract for every pool, keyed by (pool manager, pool id).
/// Anyone may `poke` a pool; every router does at the start of `distribute`, and the keeper does too.
///
/// Each poke records the spot price, and the average folds in the previous observation weighted by how long it
/// held, up to `WINDOW` (a time-weighted EMA, the way Eleos's hook keeps its own). An observation made in this
/// second has no weight yet, so a swap and a buyback in one transaction (or one block) can't move the average that
/// prices that buyback; to move it an attacker has to hold a price across time, against arbitrage and the coin's
/// tax. Until a pool has been watched for `WINDOW`, `ema` is 0, which Lodestar reads as "no buyback yet".
///
/// The first poke also records the pool's key (its hash is the id, so a key can't be faked), which `V4Swapper`
/// reads to swap by pool id.
contract V4PriceObserver {
    uint256 public constant WINDOW = 30 minutes;

    struct Observation {
        uint160 ema; // sqrtPriceX96 average up to `lastAt`
        uint64 startedAt;
        uint160 last; // spot at `lastAt`
        uint64 lastAt;
    }

    mapping(address pm => mapping(bytes32 id => Observation)) internal _obs;
    mapping(address pm => mapping(bytes32 id => V4PoolKey)) internal _keys;

    event PoolRegistered(address indexed poolManager, bytes32 indexed poolId, V4PoolKey key);
    event Observed(address indexed poolManager, bytes32 indexed poolId, uint160 spot, uint160 ema);

    /// @notice Record `key`'s spot price on `pm`. Returns the average after this observation (0 while warming up).
    function poke(address pm, V4PoolKey calldata key) external returns (uint160 emaNow) {
        bytes32 id = keccak256(abi.encode(key));
        if (_keys[pm][id].currency1 == address(0)) {
            _keys[pm][id] = key;
            emit PoolRegistered(pm, id, key);
        }
        (uint160 spot,,) = V4State.slot0(IV4PoolManager(pm), id);
        if (spot == 0) return 0; // not initialized on this pool manager
        Observation storage o = _obs[pm][id];
        if (o.startedAt == 0) {
            (o.ema, o.last, o.startedAt, o.lastAt) =
            (spot, spot, uint64(block.timestamp), uint64(block.timestamp));
        } else if (o.lastAt != block.timestamp) {
            // one observation per second: the first one in a second stands
            o.ema = _fold(o.ema, o.last, block.timestamp - o.lastAt);
            (o.last, o.lastAt) = (spot, uint64(block.timestamp));
        }
        emaNow = ema(pm, id);
        emit Observed(pm, id, spot, emaNow);
    }

    /// @notice The time-weighted average sqrtPriceX96 (currency1 per currency0) up to now, counting the latest
    /// observation for the time it has held since. 0 until the pool has been watched for `WINDOW`.
    function ema(address pm, bytes32 id) public view returns (uint160) {
        Observation memory o = _obs[pm][id];
        if (o.startedAt == 0 || block.timestamp < o.startedAt + WINDOW) return 0;
        return _fold(o.ema, o.last, block.timestamp - o.lastAt);
    }

    function observation(address pm, bytes32 id) external view returns (Observation memory) {
        return _obs[pm][id];
    }

    /// @notice The pool key recorded for `id` on `pm` (all zero if never poked).
    function keyOf(address pm, bytes32 id) external view returns (V4PoolKey memory) {
        return _keys[pm][id];
    }

    function _fold(uint160 avg, uint160 obs, uint256 dt) internal pure returns (uint160) {
        if (dt >= WINDOW) return obs;
        if (obs >= avg) return uint160(avg + uint256(obs - avg) * dt / WINDOW);
        return uint160(avg - uint256(avg - obs) * dt / WINDOW);
    }
}
