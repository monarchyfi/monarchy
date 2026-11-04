// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4FeeSource} from "./V4FeeSource.sol";
import {V4PriceObserver} from "../V4PriceObserver.sol";
import {V4PoolKey} from "../interfaces/IUniswapV4.sol";
import {IKleosHook} from "../interfaces/ILaunchpadHooks.sol";

/// @title KleosFeeSource
/// @notice Adapter for Kleos (thekleos.xyz). The hook takes each coin's buy and sell tax in HYPE and credits the
/// creator's share to the creator's address (`creatorFees(creator)`, across all their coins, so fees earned before
/// a handover stay with the old creator: claim them first). The creator claims with `claimCreatorFees()` on hooks
/// A and B, `claimCreatorFees(quote)` on the multi-quote hook C, paid in native HYPE to the caller. The role moves
/// in one call, `transferCreator(token, to)`. Version 1 supports native HYPE pools only, so a hook C coin quoted in
/// another token can't be activated, and neither can a hook C coin with a holder share (see `dividendClaim`).
contract KleosFeeSource is V4FeeSource {
    uint8 public constant KIND_SINGLE = 1; // hooks A and B
    uint8 public constant KIND_MULTI = 2; // hook C

    constructor(V4PriceObserver observer_, address owner_, address[] memory hooks_, uint8[] memory kinds_)
        V4FeeSource(observer_, owner_, hooks_, kinds_)
    {}

    function handover() external pure returns (Handover) {
        return Handover.OneStep;
    }

    function creator(address token, bytes32) external view returns (address) {
        return _tax(token).creator;
    }

    function pendingCreator(address, bytes32) external pure returns (address) {
        return address(0);
    }

    function owed(address token, bytes32, address who) external view returns (uint256, uint256) {
        return (0, _owed(token, who));
    }

    function holdersShareBps(address token, bytes32) external view returns (uint256) {
        return _tax(token).holdersBps;
    }

    /// @dev Coins on hooks A and B credit holder rewards in HYPE inside the coin, claimed by the holder with
    /// `claimRewards(holder)`. Hook C sends the holder share to a separate rewards contract that swaps it into the
    /// coin's plan tokens (stock tokens such as wNVDAx or KNTQ, checked on mainnet November 4, 2026) and streams
    /// those into the coin, which Exile can't pass on to lockers; so no claim here, and a hook C coin with a holder
    /// share can't be activated.
    function dividendClaim(address token) external view returns (address, bytes4) {
        (, uint8 kind) = _hookOfChecked(token);
        if (kind == KIND_MULTI) return (address(0), bytes4(0));
        return (token, bytes4(keccak256("claimRewards(address)")));
    }

    /// @dev The pools' LP fee is 0 (checked in `_poolKey`); a buy pays the coin's buy tax.
    function swapCostBps(address token, bytes32) external view returns (uint256) {
        return _tax(token).buyBps;
    }

    function collectCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function claimCalls(address token, bytes32, address router) external view returns (Call[] memory) {
        if (_owed(token, router) == 0) return _none();
        (address hook, uint8 kind) = _hookOfChecked(token);
        if (kind == KIND_SINGLE) return _one(hook, abi.encodeWithSignature("claimCreatorFees()"));
        return _one(hook, abi.encodeWithSignature("claimCreatorFees(address)", address(0)));
    }

    function acceptCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function transferOutCalls(address token, bytes32, address next) external view returns (Call[] memory) {
        if (next == address(0)) return _none(); // nothing is ever pending on a one-step launchpad
        (address hook,) = _hookOfChecked(token);
        return _one(hook, abi.encodeCall(IKleosHook.transferCreator, (token, next)));
    }

    function _tax(address token) internal view returns (IKleosHook.Tax memory t) {
        (address hook,) = _hookOfChecked(token);
        t = IKleosHook(hook).taxOf(token);
        if (t.token != token) revert PoolMismatch();
    }

    function _owed(address token, address who) internal view returns (uint256) {
        (address hook, uint8 kind) = _hookOfChecked(token);
        if (kind == KIND_SINGLE) return IKleosHook(hook).creatorFees(who);
        return IKleosHook(hook).creatorFees(who, address(0));
    }

    function _maxKind() internal pure override returns (uint8) {
        return KIND_MULTI;
    }

    function _poolKey(address token, address hook, uint8)
        internal
        view
        override
        returns (V4PoolKey memory key)
    {
        key = IKleosHook(hook).poolKeyOf(token);
        if (key.fee != 0) revert PoolMismatch(); // swap cost assumes no LP fee on top of the tax
    }
}
