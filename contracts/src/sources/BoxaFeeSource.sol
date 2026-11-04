// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4FeeSource} from "./V4FeeSource.sol";
import {V4PriceObserver} from "../V4PriceObserver.sol";
import {V4PoolKey} from "../interfaces/IUniswapV4.sol";
import {IBoxaHook} from "../interfaces/ILaunchpadHooks.sol";

/// @title BoxaFeeSource
/// @notice Adapter for Boxa (boxa.club). Each hook takes a fee on every swap, in HYPE on the HYPE side, and credits
/// the creator's share to the creator's address (`claimable`, across all their coins, so fees earned before a
/// handover stay with the old creator: claim them first). The creator role is two-step and per pool:
/// `proposeCreator(poolId, next)` from the creator (`next = 0` cancels), then `acceptCreator(poolId)` from `next`.
/// Holders' dividends are claimed on the hook too, `claimRewards(token, recipient)` from the holder.
///
/// Four hooks in three shapes, all read from Boxa's site code and checked against the chain on November 4, 2026:
/// - `KIND_MAIN`, the v4 hook (BOXA's): `claim(recipient)`, `claimable(payee)`. `pools(id)` is
///   (token, creator, pendingCreator, creatorBps, buybackBps, holdersBps, antiSnipe, launchTime, buyFeePips,
///   sellFeePips).
/// - `KIND_PAIRS`, the v4 pairs and meme-pairs hooks: `claim(pair, recipient)`, `claimable(pair, payee)`, with
///   `pools(id)` = (token, pair, creator, pendingCreator, creatorBps, buybackBps, holdersBps, antiSnipe,
///   launchTime, buyFeePips, sellFeePips). `pair` is the quote, 0 for HYPE.
/// - `KIND_UNI`, the current launcher's hook on its own pool manager: `claim(currency, recipient)`,
///   `claimable(payee, currency)` (note the order), `feePips(id)`, and `pools(id)` = (token, quote, creator,
///   pendingCreator, creatorBps, buybackBps, holdersBps, extraCutBps, buyExtraPips, sellExtraPips, launchTime,
///   antiSnipe, quoteIs0).
/// Every pool key is (HYPE, coin, fee 0, tick spacing 200, hook), checked against the hook's `poolOf(coin)`.
/// Version 1 supports HYPE-quoted pools only; a coin paired with another token can't be activated.
contract BoxaFeeSource is V4FeeSource {
    uint8 public constant KIND_MAIN = 1;
    uint8 public constant KIND_PAIRS = 2;
    uint8 public constant KIND_UNI = 3;

    int24 internal constant TICK_SPACING = 200;
    uint256 internal constant PIPS_PER_BPS = 100;
    bytes4 internal constant CLAIM_REWARDS_TO = bytes4(keccak256("claimRewards(address,address)"));

    /// @dev Where each field sits in `pools(id)`, by kind.
    struct Layout {
        uint8 words;
        uint8 quote; // 0 = none (the main hook only pairs with HYPE)
        uint8 creator;
        uint8 pending;
        uint8 holders;
        uint8 buyFee; // 0 = read `feePips(id)` instead
    }

    constructor(V4PriceObserver observer_, address owner_, address[] memory hooks_, uint8[] memory kinds_)
        V4FeeSource(observer_, owner_, hooks_, kinds_)
    {}

    function handover() external pure returns (Handover) {
        return Handover.TwoStep;
    }

    function creator(address token, bytes32 poolId) external view returns (address) {
        (bytes memory w, Layout memory l,) = _pool(token, poolId);
        return address(uint160(_word(w, l.creator)));
    }

    function pendingCreator(address token, bytes32 poolId) external view returns (address) {
        (bytes memory w, Layout memory l,) = _pool(token, poolId);
        return address(uint160(_word(w, l.pending)));
    }

    function owed(address token, bytes32, address who) external view returns (uint256, uint256) {
        return (0, _claimable(token, who));
    }

    function holdersShareBps(address token, bytes32 poolId) external view returns (uint256) {
        (bytes memory w, Layout memory l,) = _pool(token, poolId);
        return _word(w, l.holders);
    }

    /// @dev Boxa keeps holder dividends on the hook: the holder calls `claimRewards(token, recipient)` there.
    function dividendClaim(address token) external view returns (address, bytes4) {
        (address hook,) = _hookOfChecked(token);
        return (hook, CLAIM_REWARDS_TO);
    }

    /// @dev The LP fee is 0; the hook's buy fee comes off the HYPE paid in. Rounded up to whole basis points.
    function swapCostBps(address token, bytes32 poolId) external view returns (uint256) {
        (bytes memory w, Layout memory l, address hook) = _pool(token, poolId);
        uint256 pips;
        if (l.buyFee != 0) {
            pips = _word(w, l.buyFee);
        } else {
            (pips,) = IBoxaHook(hook).feePips(poolId);
        }
        return (pips + PIPS_PER_BPS - 1) / PIPS_PER_BPS;
    }

    function collectCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function claimCalls(address token, bytes32, address router) external view returns (Call[] memory) {
        if (_claimable(token, router) == 0) return _none();
        (address hook, uint8 kind) = _hookOfChecked(token);
        if (kind == KIND_MAIN) return _one(hook, abi.encodeWithSignature("claim(address)", router));
        // pairs: claim(pair, recipient); uni: claim(currency, recipient); both with HYPE = address(0)
        return _one(hook, abi.encodeWithSignature("claim(address,address)", address(0), router));
    }

    function acceptCalls(address token, bytes32 poolId, address) external view returns (Call[] memory) {
        (address hook,) = _hookOfChecked(token);
        return _one(hook, abi.encodeCall(IBoxaHook.acceptCreator, (poolId)));
    }

    /// @dev `next = 0` cancels a pending proposal (checked on all four hooks).
    function transferOutCalls(address token, bytes32 poolId, address next)
        external
        view
        returns (Call[] memory)
    {
        (address hook,) = _hookOfChecked(token);
        return _one(hook, abi.encodeCall(IBoxaHook.proposeCreator, (poolId, next)));
    }

    // ---------------------------------------------------------------- internals

    function _maxKind() internal pure override returns (uint8) {
        return KIND_UNI;
    }

    function _poolKey(address token, address hook, uint8 kind)
        internal
        view
        override
        returns (V4PoolKey memory key)
    {
        bytes32 id = IBoxaHook(hook).poolOf(token);
        Layout memory l = _layout(kind);
        bytes memory w = _words(hook, id, l);
        if (address(uint160(_word(w, 0))) != token) revert PoolMismatch();
        if (l.quote != 0 && _word(w, l.quote) != 0) revert QuoteUnsupported();
        key = V4PoolKey(address(0), token, 0, TICK_SPACING, hook);
        if (keccak256(abi.encode(key)) != id) revert PoolMismatch();
    }

    function _claimable(address token, address who) internal view returns (uint256) {
        (address hook, uint8 kind) = _hookOfChecked(token);
        if (kind == KIND_MAIN) return IBoxaHook(hook).claimable(who);
        if (kind == KIND_PAIRS) return IBoxaHook(hook).claimable(address(0), who); // (pair, payee)
        return IBoxaHook(hook).claimable(who, address(0)); // uni: (payee, currency)
    }

    /// @dev The pool's words, checked to belong to `token`.
    function _pool(address token, bytes32 poolId)
        internal
        view
        returns (bytes memory w, Layout memory l, address hook)
    {
        uint8 kind;
        (hook, kind) = _hookOfChecked(token);
        l = _layout(kind);
        w = _words(hook, poolId, l);
        if (address(uint160(_word(w, 0))) != token) revert PoolMismatch();
    }

    function _words(address hook, bytes32 poolId, Layout memory l) internal view returns (bytes memory w) {
        bool ok;
        (ok, w) = hook.staticcall(abi.encodeWithSignature("pools(bytes32)", poolId));
        if (!ok || w.length < uint256(l.words) * 32) revert PoolMismatch();
    }

    function _word(bytes memory w, uint256 i) internal pure returns (uint256 x) {
        assembly ("memory-safe") {
            x := mload(add(w, add(32, mul(i, 32))))
        }
    }

    function _layout(uint8 kind) internal pure returns (Layout memory) {
        if (kind == KIND_MAIN) {
            return Layout({words: 10, quote: 0, creator: 1, pending: 2, holders: 5, buyFee: 8});
        }
        if (kind == KIND_PAIRS) {
            return Layout({words: 11, quote: 1, creator: 2, pending: 3, holders: 6, buyFee: 9});
        }
        return Layout({words: 13, quote: 1, creator: 2, pending: 3, holders: 6, buyFee: 0});
    }
}
