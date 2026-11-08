// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4FeeSource} from "./V4FeeSource.sol";
import {V4PriceObserver} from "../V4PriceObserver.sol";
import {V4PoolKey} from "../interfaces/IUniswapV4.sol";
import {IElysPumpHook} from "../interfaces/ILaunchpadHooks.sol";

/// @title ElysPumpFeeSource
/// @notice Adapter for ElysPump (elysp.com), its v2 and v3 hooks (the same contract, on two pool managers). The hook
/// takes each coin's buy and sell fee in the quote, keeps 30% for the platform and splits the rest by the shares
/// the coin was launched with: the fee receiver's share is credited to the receiver's address (`owed(receiver,
/// quote)`, across all the coins it receives for, so fees earned before a handover stay with the old receiver:
/// claim them first), the holders' share is paid out as dividends inside the coin, and the buyback share is spent
/// by the hook itself. The receiver claims with `claim(quote)`, paid to the caller; the role moves in one call,
/// `setFeeReceiver(token, to)`, from the current receiver. Shares are fixed at launch.
///
/// Version 1 supports native HYPE coins only (four early v2 coins are quoted in KNTQ), and not ElysPump's first
/// launchpad, which runs on Uniswap v3. A coin whose receiver share is 0 has nothing for a router to route, so it
/// can't be activated (`NoReceiverShare`).
contract ElysPumpFeeSource is V4FeeSource {
    uint8 public constant KIND_HOOK = 1; // the v2 and v3 hooks

    /// @dev The fields of `launches(token)` this adapter reads, by word.
    uint256 internal constant W_RECEIVER = 1;
    uint256 internal constant W_QUOTE = 2;
    uint256 internal constant W_RECEIVER_SHARE = 5;
    uint256 internal constant W_HOLDERS_SHARE = 6;
    uint256 internal constant LAUNCH_WORDS = 13;

    error NoReceiverShare();
    error UnknownCoin();

    constructor(V4PriceObserver observer_, address owner_, address[] memory hooks_, uint8[] memory kinds_)
        V4FeeSource(observer_, owner_, hooks_, kinds_)
    {}

    function handover() external pure returns (Handover) {
        return Handover.OneStep;
    }

    /// @dev On top of the base checks: the coin must pay its fee receiver something.
    function resolve(address token, address quote)
        public
        view
        override
        returns (bytes32 poolId, address hook, bool tokenIs0)
    {
        (poolId, hook, tokenIs0) = super.resolve(token, quote);
        if (_word(token, W_RECEIVER_SHARE) == 0) revert NoReceiverShare();
    }

    function creator(address token, bytes32) external view returns (address) {
        return address(uint160(_word(token, W_RECEIVER)));
    }

    function pendingCreator(address, bytes32) external pure returns (address) {
        return address(0);
    }

    function owed(address token, bytes32, address who) external view returns (uint256, uint256) {
        return (0, _owed(token, who));
    }

    function holdersShareBps(address token, bytes32) external view returns (uint256) {
        return _word(token, W_HOLDERS_SHARE);
    }

    /// @notice The fee receiver's share of the coin's fee after the platform's 30%, in bps (0 = it can't be
    /// activated). Reverts like `resolve` for a coin this adapter doesn't serve.
    function receiverShareBps(address token) external view returns (uint256) {
        return _word(token, W_RECEIVER_SHARE);
    }

    /// @dev Holders claim their dividends from the coin with `claim()`, paid to the caller in native HYPE.
    function dividendClaim(address token) external view returns (address, bytes4) {
        _hookOfChecked(token);
        return (token, bytes4(keccak256("claim()")));
    }

    /// @dev The pools' LP fee is 0 (checked in `_poolKey`); a buy pays the coin's buy fee, or its snipe fee in the
    /// first seconds after launch.
    function swapCostBps(address token, bytes32) external view returns (uint256) {
        (address hook,) = _hookOfChecked(token);
        return IElysPumpHook(hook).currentBuyFeeBps(token);
    }

    function collectCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function claimCalls(address token, bytes32, address router) external view returns (Call[] memory) {
        if (_owed(token, router) == 0) return _none();
        (address hook,) = _hookOfChecked(token);
        return _one(hook, abi.encodeCall(IElysPumpHook.claim, (address(0))));
    }

    function acceptCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function transferOutCalls(address token, bytes32, address next) external view returns (Call[] memory) {
        if (next == address(0)) return _none(); // nothing is ever pending on a one-step launchpad
        (address hook,) = _hookOfChecked(token);
        return _one(hook, abi.encodeCall(IElysPumpHook.setFeeReceiver, (token, next)));
    }

    function _owed(address token, address who) internal view returns (uint256) {
        (address hook,) = _hookOfChecked(token);
        return IElysPumpHook(hook).owed(who, address(0));
    }

    /// @dev One word of the coin's `launches` tuple. The hook answers zeros for a coin it didn't launch, so a coin
    /// with no creator is refused; so is one quoted in anything but native HYPE.
    function _word(address token, uint256 i) internal view returns (uint256 w) {
        (address hook,) = _hookOfChecked(token);
        (bool ok, bytes memory r) =
            hook.staticcall(abi.encodeWithSignature("launches(address)", token));
        if (!ok || r.length < LAUNCH_WORDS * 32) revert UnknownCoin();
        address launcher;
        address quote;
        assembly {
            launcher := mload(add(r, 32))
            quote := mload(add(r, add(32, mul(W_QUOTE, 32))))
            w := mload(add(r, add(32, mul(i, 32))))
        }
        if (launcher == address(0)) revert UnknownCoin();
        if (quote != address(0)) revert QuoteUnsupported();
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
        key = IElysPumpHook(hook).keyOf(token);
        if (key.fee != 0) revert PoolMismatch(); // swap cost assumes no LP fee on top of the coin's fee
    }
}
