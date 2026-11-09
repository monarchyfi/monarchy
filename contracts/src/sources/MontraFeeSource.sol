// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4FeeSource} from "./V4FeeSource.sol";
import {V4PriceObserver} from "../V4PriceObserver.sol";
import {V4PoolKey} from "../interfaces/IUniswapV4.sol";
import {IMontraHook, IMontraToken} from "../interfaces/ILaunchpadHooks.sol";

/// @title MontraFeeSource
/// @notice Adapter for Montra (montramarkets.xyz), whose launch hook runs on Elysium's official Uniswap v4 pool
/// manager. Each coin trades in one dynamic-fee pool, native HYPE against the coin. Every trade pays the coin's
/// tier (1% to 10%): 0.4% goes to Montra, the pool's liquidity providers take an LP fee once the pool passes its LP
/// line, and the rest, the creator side, waits in the hook for the pool's one recipient (a wallet, a splitter, or
/// the coin's holders), in HYPE.
///
/// The recipient claims with `claim(poolId, to)` and hands the stream on with `updateRecipient(poolId, next)`, at
/// once (one step). The hook keeps the fees by pool, not by address, so whatever is unclaimed at a handover goes
/// with it: a creator should claim before handing over, or the router routes it. Only a pool paid to one wallet can
/// be activated: a splitter can't call the factory, and a coin paying its holders can never change recipient
/// (`FeesGoToHolders`). Version 1 supports native HYPE coins only.
contract MontraFeeSource is V4FeeSource {
    uint8 public constant KIND_HOOK = 1;
    /// @dev Montra's name for a coin's holders as a recipient; naming the coin itself means the same.
    address internal constant HOLDERS = address(1);

    error FeesGoToHolders();

    constructor(V4PriceObserver observer_, address owner_, address[] memory hooks_, uint8[] memory kinds_)
        V4FeeSource(observer_, owner_, hooks_, kinds_)
    {}

    function handover() external pure returns (Handover) {
        return Handover.OneStep;
    }

    /// @dev On top of the base checks: the creator side must be paid to an address that can hand it on.
    function resolve(address token, address quote)
        public
        view
        override
        returns (bytes32 poolId, address hook, bool tokenIs0)
    {
        (poolId, hook, tokenIs0) = super.resolve(token, quote);
        address r = IMontraHook(hook).recipientOf(poolId);
        if (r == token || r == HOLDERS) revert FeesGoToHolders();
    }

    function creator(address token, bytes32) external view returns (address) {
        (address hook, bytes32 id) = _pool(token);
        return IMontraHook(hook).recipientOf(id);
    }

    function pendingCreator(address, bytes32) external pure returns (address) {
        return address(0);
    }

    /// @dev What the recipient's claim would pay now: the swept tab and what a sweep would add (the locked seed's
    /// unharvested LP fees, which the claim also collects, aren't counted).
    function owed(address token, bytes32, address who) public view returns (uint256, uint256) {
        (address hook, bytes32 id) = _pool(token);
        if (IMontraHook(hook).recipientOf(id) != who) return (0, 0);
        return (0, IMontraHook(hook).tab(id) + IMontraHook(hook).pendingCreator(id));
    }

    /// @dev The holders earn the creator side only when they are its recipient, which an activated coin's never is.
    function holdersShareBps(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function dividendClaim(address) external pure returns (address, bytes4) {
        return (address(0), bytes4(0));
    }

    /// @dev What a buy pays this second, all in (the hook's part and the LP fee), rounded up to whole bps: the
    /// coin's tier, or more inside its anti-snipe window.
    function swapCostBps(address token, bytes32) external view returns (uint256) {
        (address hook, bytes32 id) = _pool(token);
        return (IMontraHook(hook).currentBuyFeeRate(id) + 99) / 100;
    }

    function collectCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function claimCalls(address token, bytes32, address router) external view returns (Call[] memory) {
        (, uint256 q) = owed(token, bytes32(0), router);
        if (q == 0) return _none();
        (address hook, bytes32 id) = _pool(token);
        return _one(hook, abi.encodeCall(IMontraHook.claim, (id, router)));
    }

    function acceptCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function transferOutCalls(address token, bytes32, address next) external view returns (Call[] memory) {
        if (next == address(0)) return _none(); // nothing is ever pending on a one-step launchpad
        (address hook, bytes32 id) = _pool(token);
        return _one(hook, abi.encodeCall(IMontraHook.updateRecipient, (id, next)));
    }

    /// @dev The coin's registered hook and its pool id, checked against the hook's own key for the pool.
    function _pool(address token) internal view returns (address hook, bytes32 id) {
        (hook,) = _hookOfChecked(token);
        id = IMontraToken(token).poolId();
        V4PoolKey memory key = IMontraHook(hook).poolKey(id);
        if (key.currency1 != token || key.hooks != hook || keccak256(abi.encode(key)) != id) revert PoolMismatch();
    }

    function _maxKind() internal pure override returns (uint8) {
        return KIND_HOOK;
    }

    function _poolKey(address token, address hook, uint8)
        internal
        view
        override
        returns (V4PoolKey memory key)
    {
        key = IMontraHook(hook).poolKey(IMontraToken(token).poolId());
    }
}
