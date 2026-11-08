// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What a Lodestar needs to know about the launchpad that holds its token's creator role. One adapter
/// per launchpad (Ascend, Boxa, Kleos, Eleos, ElysPump) answers views and builds the calls the router sends
/// itself, since a launchpad only answers the address that holds the creator role. A router stores its adapter
/// once, at initialize, and only ever sends a call to the pool's `hook` (the contract that holds the role), never
/// with value, so an adapter cannot turn a router into a generic caller.
interface IFeeSource {
    /// @dev TwoStep: the creator proposes the router and the router accepts (Ascend testnet, Boxa). OneStep: the
    /// creator hands the role over in one call and there is nothing to accept (Kleos, Eleos, ElysPump).
    /// TwoStepDelayed: like TwoStep, but the router can only accept after a wait (Ascend v5, 48 hours), so the
    /// factory deploys the router without accepting and anyone calls `Lodestar.acceptCreator()` once the wait is
    /// over.
    enum Handover {
        TwoStep,
        OneStep,
        TwoStepDelayed
    }

    struct Call {
        address target;
        bytes data;
    }

    function handover() external view returns (Handover);

    /// @notice The pool for `token` against `quote` (address(0) = native HYPE): its id (also the router's CREATE2
    /// salt), the contract that holds the creator role, and whether the token is currency0. Reverts for a pair
    /// the adapter doesn't support.
    function resolve(address token, address quote)
        external
        view
        returns (bytes32 poolId, address hook, bool tokenIs0);

    /// @notice The launchpad's listing desk, or address(0) when it has none.
    function desk() external view returns (address);

    function creator(address token, bytes32 poolId) external view returns (address);

    /// @notice The address a two-step handover is waiting on; always address(0) for OneStep launchpads.
    function pendingCreator(address token, bytes32 poolId) external view returns (address);

    /// @notice Creator fees `who` could claim now, in the token and in the quote.
    function owed(address token, bytes32 poolId, address who)
        external
        view
        returns (uint256 tokenSide, uint256 quoteSide);

    /// @notice The share of the launchpad's fee split that the token pays its holders as dividends inside the
    /// token (0 on Ascend). Coins locked in Exile earn those too, so a router for such a token needs Exile's harvest.
    function holdersShareBps(address token, bytes32 poolId) external view returns (uint256);

    /// @notice How a holder claims the dividends the token pays by balance, for Exile's harvest: the holder calls
    /// `selector(holder)` on the token when `target` is the token (or just `claim()`, which pays the caller), or
    /// `selector(token, holder)` on `target` (the coin's hook) otherwise. (0, 0) = the token pays none, or the
    /// adapter doesn't know how to claim them.
    function dividendClaim(address token) external view returns (address target, bytes4 selector);

    /// @notice Where buybacks and token-side burns go: the address the token already counts as burned.
    function burnSink(address token) external view returns (address);

    /// @notice What a buy costs on top of the price right now, in bps of the quote paid: the LP fee plus any tax.
    function swapCostBps(address token, bytes32 poolId) external view returns (uint256);

    /// @notice Spot and reference (EMA) sqrt prices as Q64.96 currency1 per currency0, and the active liquidity.
    /// Any of them is 0 when it can't be read; a 0 EMA means no buyback.
    function prices(address token, bytes32 poolId)
        external
        view
        returns (uint160 spotSqrtPriceX96, uint160 emaSqrtPriceX96, uint128 liquidity);

    /// @notice Record the pool's price with whatever observer the adapter uses. Anyone may call it; a router calls
    /// it at the start of every distribute and ignores a failure.
    function poke(address token, bytes32 poolId) external;

    /// @notice Calls that move accrued fees to where the creator can claim them (Ascend `collect`, Eleos
    /// `process`). Empty when there is nothing to do.
    function collectCalls(address token, bytes32 poolId, address router) external view returns (Call[] memory);

    /// @notice Calls that pay the creator's fees to `router`. Empty when nothing is owed.
    function claimCalls(address token, bytes32 poolId, address router) external view returns (Call[] memory);

    /// @notice Calls that complete a two-step handover to `router`. Empty for OneStep launchpads.
    function acceptCalls(address token, bytes32 poolId, address router) external view returns (Call[] memory);

    /// @notice Calls that hand the creator role to `next`. On TwoStep launchpads `next = 0` cancels a pending
    /// handover; on OneStep launchpads it is a no-op (empty).
    function transferOutCalls(address token, bytes32 poolId, address next)
        external
        view
        returns (Call[] memory);
}
