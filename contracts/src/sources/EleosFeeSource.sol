// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4FeeSource} from "./V4FeeSource.sol";
import {V4PriceObserver} from "../V4PriceObserver.sol";
import {V4PoolKey} from "../interfaces/IUniswapV4.sol";
import {IEleosHook} from "../interfaces/ILaunchpadHooks.sol";

/// @title EleosFeeSource
/// @notice Adapter for Eleos (eleos.fun). Each coin's tax is held by the hook until anyone calls `process(coin)`,
/// which credits the creator's share to the coin's book (`creatorOwed`, per coin, so it moves with the role);
/// `payCreator(coin)` then pushes it to the creator in native HYPE. The creator role moves in one call,
/// `transferCreator(coin, to)`, sent by the creator recorded in the hook (`config(coin).creator`, which for
/// bundler launches is not the coin's own `creator()`). Coins pay holders HYPE dividends inside the coin,
/// claimable for any holder with `claimFor(holder)`.
/// `process` only runs with at least 0.005 HYPE pending and the price within 400 ticks of the hook's 10 minute
/// average; otherwise the collect step is skipped and the tax waits in the hook for the next distribute.
contract EleosFeeSource is V4FeeSource {
    uint8 public constant KIND_HOOK = 1; // hooks 1, 2 and 3 share this ABI
    uint256 internal constant BPS = 10_000;

    constructor(V4PriceObserver observer_, address owner_, address[] memory hooks_, uint8[] memory kinds_)
        V4FeeSource(observer_, owner_, hooks_, kinds_)
    {}

    function handover() external pure returns (Handover) {
        return Handover.OneStep;
    }

    function creator(address token, bytes32) external view returns (address) {
        (address hook,) = _hookOfChecked(token);
        return IEleosHook(hook).config(token).creator;
    }

    function pendingCreator(address, bytes32) external pure returns (address) {
        return address(0);
    }

    /// @dev What the creator would be paid now, plus their share of the tax a `process` would split right now.
    function owed(address token, bytes32, address who)
        external
        view
        returns (uint256 tokenSide, uint256 quoteSide)
    {
        (address hook,) = _hookOfChecked(token);
        IEleosHook.Config memory c = IEleosHook(hook).config(token);
        if (who != c.creator) return (0, 0);
        IEleosHook.Book memory b = IEleosHook(hook).book(token);
        quoteSide = b.creatorOwed;
        (bool ok,,,) = IEleosHook(hook).processable(token);
        if (ok) {
            uint256 normal = b.pending;
            uint256 rest = normal - normal * IEleosHook(hook).platformBps() / BPS;
            quoteSide += rest * c.creatorBps / BPS;
        }
    }

    function holdersShareBps(address token, bytes32) external view returns (uint256) {
        (address hook,) = _hookOfChecked(token);
        return IEleosHook(hook).config(token).holdersBps;
    }

    function dividendClaim(address token) external pure returns (address, bytes4) {
        return (token, bytes4(keccak256("claimFor(address)")));
    }

    /// @dev The LP fee is 0; the buy tax right now includes any anti-snipe surcharge.
    function swapCostBps(address token, bytes32) external view returns (uint256 buyBps) {
        (address hook,) = _hookOfChecked(token);
        (buyBps,) = IEleosHook(hook).taxNow(token);
    }

    function collectCalls(address token, bytes32, address) external view returns (Call[] memory) {
        (address hook,) = _hookOfChecked(token);
        (bool ok,,,) = IEleosHook(hook).processable(token);
        if (!ok) return _none();
        return _one(hook, abi.encodeCall(IEleosHook.process, (token)));
    }

    function claimCalls(address token, bytes32, address router) external view returns (Call[] memory) {
        (address hook,) = _hookOfChecked(token);
        // payCreator pays `config.creator`, so only ask when this router is it and something is owed
        if (IEleosHook(hook).config(token).creator != router) return _none();
        if (IEleosHook(hook).book(token).creatorOwed == 0) return _none();
        return _one(hook, abi.encodeCall(IEleosHook.payCreator, (token)));
    }

    function acceptCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function transferOutCalls(address token, bytes32, address next) external view returns (Call[] memory) {
        if (next == address(0)) return _none(); // nothing is ever pending on a one-step launchpad
        (address hook,) = _hookOfChecked(token);
        return _one(hook, abi.encodeCall(IEleosHook.transferCreator, (token, next)));
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
        key = IEleosHook(hook).keyFor(token);
        if (keccak256(abi.encode(key)) != IEleosHook(hook).poolIdOf(token)) revert PoolMismatch();
    }
}
