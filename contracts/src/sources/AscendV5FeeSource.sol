// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFeeSource} from "../interfaces/IFeeSource.sol";
import {IAscendV5Launchpad, IAscendV5EscrowFactory, IAscendV5Escrow} from "../interfaces/IAscendV5.sol";
import {IV4PoolManager, V4PoolKey} from "../interfaces/IUniswapV4.sol";
import {V4State} from "../libraries/V4State.sol";

/// @title AscendV5FeeSource
/// @notice The fee-source adapter for Ascend v5 on Elysium mainnet (Uniswap v4 pools, the launchpad as every launch
/// pool's hook). On v5 each pool's creator role is its own CreatorEscrow, and what a router takes over is the
/// escrow's `recipient`:
///   - handover: the recipient calls `escrow.proposeRecipient(router)`; after the escrow's 48 hour wait anyone calls
///     `Lodestar.acceptCreator()`, which sends `escrow.acceptRecipient()`;
///   - fees: the launchpad takes each pool's fee in the quote (WHYPE, USDC, KNTQ), `collect` books it to the escrow,
///     `claim` pays the escrow, and the escrow credits the recipient by the pool's launch rules (most of it held
///     until the coin graduates, see Ascend's docs). Both launchpad calls are permissionless, so this adapter sends
///     them itself from `poke`, which every distribute calls first; the router then sends `escrow.claim(router)`.
///     There is no token-side fee on v5.
/// Only Vanilla coins can switch: on Holder Rewards, Buyback and Custom mix coins the recipient is Ascend's seat
/// contract, which never proposes a new recipient. Credits paid out before the handover stay with the old
/// recipient, but fees still held (below the graduation line) go to whoever is the recipient when the coin
/// graduates: hand-off moves the creator's held fees to the router, and a later hand-out moves the router's.
/// Pools that opted in to Ascend's community takeovers (`takeoverRegistry` not zero) can have the recipient
/// replaced by Ascend's CTO registry after its review and notice, whatever this router's creator lock says.
/// Stateless.
contract AscendV5FeeSource is IFeeSource {
    /// @dev Uniswap v4's dynamic-fee flag and Ascend's tick spacing: every v5 launch pool's key.
    uint24 public constant DYNAMIC_FEE = 0x800000;
    int24 public constant TICK_SPACING = 200;

    IAscendV5Launchpad public immutable launchpad;
    IAscendV5EscrowFactory public immutable escrowFactory;
    IV4PoolManager public immutable poolManager;
    /// @notice Ascend's BurnSink: immutable custody with no withdrawal. v5 coins reject transfers to address(0)
    /// and to 0x…dEaD, and Ascend counts this address as burned.
    address public immutable sink;

    error QuoteUnsupported();
    error UnknownPool();
    error PoolMismatch();
    error ZeroAddress();

    constructor(IAscendV5Launchpad launchpad_, address sink_) {
        if (address(launchpad_) == address(0) || sink_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        escrowFactory = IAscendV5EscrowFactory(launchpad_.escrowFactory());
        poolManager = IV4PoolManager(launchpad_.poolManager());
        if (address(escrowFactory) == address(0) || address(poolManager) == address(0)) revert ZeroAddress();
        if (escrowFactory.launchpad() != address(launchpad_)) revert PoolMismatch();
        sink = sink_;
    }

    function handover() external pure returns (Handover) {
        return Handover.TwoStepDelayed;
    }

    /// @notice The launch pool's key: the pair sorted, the dynamic-fee flag, tick spacing 200, the launchpad as hook.
    function poolKey(address token, address quote) public view returns (V4PoolKey memory key) {
        (address c0, address c1) = token < quote ? (token, quote) : (quote, token);
        key = V4PoolKey(c0, c1, DYNAMIC_FEE, TICK_SPACING, address(launchpad));
    }

    /// @notice The escrow that holds a pool's creator role, or address(0).
    function escrowOf(bytes32 poolId) public view returns (IAscendV5Escrow) {
        return IAscendV5Escrow(escrowFactory.escrowOf(poolId));
    }

    /// @dev v5 pools are quoted in an ERC-20 (a HYPE pair uses WHYPE), so native HYPE (address(0)) is refused.
    function resolve(address token, address quote)
        external
        view
        returns (bytes32 poolId, address hook, bool tokenIs0)
    {
        if (quote == address(0)) revert QuoteUnsupported();
        poolId = keccak256(abi.encode(poolKey(token, quote)));
        IAscendV5Escrow e = escrowOf(poolId);
        if (address(e) == address(0)) revert UnknownPool();
        if (e.token() != token || e.quote() != quote) revert PoolMismatch();
        hook = address(e);
        tokenIs0 = token < quote;
    }

    /// @dev v5's listing elections run on the escrow, not through a desk this router can enrol with.
    function desk() external pure returns (address) {
        return address(0);
    }

    /// @dev The contract that holds the role pays its fees.
    function payer(address) external pure returns (address) {
        return address(0);
    }

    /// @notice Ascend's community-takeover registry for the pool, or address(0) when the pool did not opt in. When
    /// set, an approved takeover replaces the escrow's recipient (this router included) after the registry's notice.
    function takeoverRegistry(bytes32 poolId) external view returns (address) {
        return escrowOf(poolId).ctoRegistry();
    }

    function creator(address, bytes32 poolId) external view returns (address) {
        return escrowOf(poolId).recipient();
    }

    function pendingCreator(address, bytes32 poolId) external view returns (address) {
        return escrowOf(poolId).pendingRecipient();
    }

    /// @dev Credited to `who` and claimable now. Fees still in the pool or not yet released are not included.
    function owed(address, bytes32 poolId, address who)
        external
        view
        returns (uint256 tokenSide, uint256 quoteSide)
    {
        return (0, escrowOf(poolId).claimable(who));
    }

    function holdersShareBps(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function dividendClaim(address) external pure returns (address, bytes4) {
        return (address(0), bytes4(0));
    }

    function burnSink(address) external view returns (address) {
        return sink;
    }

    /// @dev The pool's fixed fee (creator's choice plus any builder fee), pips rounded up to bps.
    function swapCostBps(address, bytes32 poolId) external view returns (uint256) {
        return (uint256(launchpad.currentFee(poolId)) + 99) / 100;
    }

    /// @dev Spot and liquidity from the pool manager's storage, the EMA that Ascend's hook keeps itself.
    function prices(address, bytes32 poolId)
        external
        view
        returns (uint160 spot, uint160 ema, uint128 liquidity)
    {
        (spot,,) = V4State.slot0(poolManager, poolId);
        liquidity = V4State.liquidity(poolManager, poolId);
        try launchpad.emaSqrtPrice(poolId) returns (uint160 e) {
            ema = e;
        } catch {}
    }

    /// @notice Move a pool's accrued fees into its escrow: `collect` then `claim` on the launchpad, both
    /// permissionless. A router calls this at the start of every distribute and ignores a failure; so may anyone.
    function poke(address, bytes32 poolId) external {
        try launchpad.collect(poolId) {} catch {}
        try launchpad.claim(poolId) {} catch {}
    }

    /// @dev Done in `poke`: the router only sends calls to its escrow.
    function collectCalls(address, bytes32, address) external pure returns (Call[] memory cs) {
        cs = new Call[](0);
    }

    function claimCalls(address, bytes32 poolId, address router) external view returns (Call[] memory cs) {
        IAscendV5Escrow e = escrowOf(poolId);
        if (e.claimable(router) == 0) return new Call[](0);
        cs = _one(e, abi.encodeCall(IAscendV5Escrow.claim, (router)));
    }

    function acceptCalls(address, bytes32 poolId, address) external view returns (Call[] memory cs) {
        cs = _one(escrowOf(poolId), abi.encodeCall(IAscendV5Escrow.acceptRecipient, ()));
    }

    /// @dev `next = 0` proposes no one, which cancels a pending hand-off.
    function transferOutCalls(address, bytes32 poolId, address next)
        external
        view
        returns (Call[] memory cs)
    {
        cs = _one(escrowOf(poolId), abi.encodeCall(IAscendV5Escrow.proposeRecipient, (next)));
    }

    function _one(IAscendV5Escrow e, bytes memory data) internal pure returns (Call[] memory cs) {
        cs = new Call[](1);
        cs[0] = Call(address(e), data);
    }
}
