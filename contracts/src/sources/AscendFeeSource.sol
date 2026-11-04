// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFeeSource} from "../interfaces/IFeeSource.sol";
import {IAscendLaunchpad} from "../interfaces/IAscendLaunchpad.sol";
import {IListingDesk} from "../interfaces/IListingDesk.sol";
import {ICLPoolManager} from "../interfaces/IInfinity.sol";
import {AscendPoolKey} from "../libraries/AscendPoolKey.sol";

/// @title AscendFeeSource
/// @notice The fee-source adapter for Ascend's launchpad (PancakeSwap Infinity pools). It wraps the calls a
/// Lodestar made to Ascend directly before adapters existed, one to one: `collect` and `claim` on distribute,
/// the two-step `transferCreator` / `acceptCreator` handover, Ascend's own EMA price and the pool's slot0 and
/// liquidity for buybacks. Stateless.
contract AscendFeeSource is IFeeSource {
    /// @dev Ascend's 1% pool fee.
    uint256 public constant SWAP_FEE_BPS = 100;
    /// @dev Ascend's launch tokens reject transfers to address(0) and to 0x…dEaD, so burns go to this widely used
    /// dead address instead. Nobody holds its key.
    address public constant DEAD = 0xdEAD000000000000000042069420694206942069;

    IAscendLaunchpad public immutable launchpad;
    IListingDesk internal immutable _desk;
    ICLPoolManager public immutable poolManager;

    error DeskMismatch();

    constructor(IAscendLaunchpad launchpad_, IListingDesk desk_, ICLPoolManager poolManager_) {
        if (launchpad_.listingDesk() != address(desk_)) revert DeskMismatch();
        launchpad = launchpad_;
        _desk = desk_;
        poolManager = poolManager_;
    }

    function handover() external pure returns (Handover) {
        return Handover.TwoStep;
    }

    /// @dev The pool id sorts the pair, so a swapped token and quote give the same id; the launchpad's own
    /// orientation tells the factory which way round they really are.
    function resolve(address token, address quote)
        external
        view
        returns (bytes32 poolId, address hook, bool tokenIs0)
    {
        poolId = AscendPoolKey.id(token, quote, address(launchpad), address(poolManager));
        hook = address(launchpad);
        tokenIs0 = token < quote;
        try launchpad.poolTokenIs0(poolId) returns (bool b) {
            tokenIs0 = b;
        } catch {}
    }

    function desk() external view returns (address) {
        return address(_desk);
    }

    function creator(address, bytes32 poolId) external view returns (address) {
        return launchpad.poolCreator(poolId);
    }

    function pendingCreator(address, bytes32 poolId) external view returns (address) {
        return launchpad.pendingCreator(poolId);
    }

    /// @dev Ascend keeps what the creator is owed per pool, so it follows the role.
    function owed(address, bytes32 poolId, address)
        external
        view
        returns (uint256 tokenSide, uint256 quoteSide)
    {
        return (launchpad.creatorOwedToken(poolId), launchpad.creatorOwedQuote(poolId));
    }

    function holdersShareBps(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function dividendClaim(address) external pure returns (address, bytes4) {
        return (address(0), bytes4(0));
    }

    function burnSink(address) external pure returns (address) {
        return DEAD;
    }

    function swapCostBps(address, bytes32) external pure returns (uint256) {
        return SWAP_FEE_BPS;
    }

    function prices(address, bytes32 poolId)
        external
        view
        returns (uint160 spot, uint160 ema, uint128 liquidity)
    {
        try poolManager.getSlot0(poolId) returns (uint160 s, int24, uint24, uint24) {
            spot = s;
        } catch {}
        try launchpad.emaSqrtPrice(poolId) returns (uint160 e) {
            ema = e;
        } catch {}
        try poolManager.getLiquidity(poolId) returns (uint128 l) {
            liquidity = l;
        } catch {}
    }

    /// @dev Ascend keeps its own EMA; nothing to record.
    function poke(address, bytes32) external {}

    function collectCalls(address, bytes32 poolId, address) external view returns (Call[] memory cs) {
        cs = _one(abi.encodeCall(IAscendLaunchpad.collect, (poolId)));
    }

    function claimCalls(address, bytes32 poolId, address) external view returns (Call[] memory cs) {
        cs = _one(abi.encodeCall(IAscendLaunchpad.claim, (poolId)));
    }

    function acceptCalls(address, bytes32 poolId, address) external view returns (Call[] memory cs) {
        cs = _one(abi.encodeCall(IAscendLaunchpad.acceptCreator, (poolId)));
    }

    function transferOutCalls(address, bytes32 poolId, address next)
        external
        view
        returns (Call[] memory cs)
    {
        cs = _one(abi.encodeCall(IAscendLaunchpad.transferCreator, (poolId, next)));
    }

    function _one(bytes memory data) internal view returns (Call[] memory cs) {
        cs = new Call[](1);
        cs[0] = Call(address(launchpad), data);
    }
}
