// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IExile {
    /// @param minDuration shortest lock length (seconds) that qualifies for this tier
    /// @param multiplierBps reward multiplier, 10_000 = 1x
    /// @param label display name, e.g. "Monarch"
    struct Tier {
        uint32 minDuration;
        uint16 multiplierBps;
        bytes32 label;
    }

    /// @notice Start a reward pool for lockers of `stakeToken`, paid in `rewardToken` (address(0) = native HYPE).
    /// Tiers must be sorted by minDuration ascending. `admin` may change tiers behind a 12 hour timelock.
    function createPool(address stakeToken, address rewardToken, Tier[] calldata tiers, address admin)
        external
        returns (uint256 poolId);

    /// @notice Add rewards to a pool. They drip out over 3 days. Anyone may call. A native pool takes exactly
    /// `amount` as msg.value.
    function notifyReward(uint256 poolId, uint256 amount) external payable;

    /// @notice Add rewards paid in the pool's stake token. They drip out over 3 days on the same points,
    /// next to the reward-token stream. Anyone may call.
    function notifyStakeReward(uint256 poolId, uint256 amount) external;

    /// @notice Catch a pool up by at most `maxBuckets` hours. Returns true once it has reached the present.
    function poke(uint256 poolId, uint256 maxBuckets) external returns (bool caughtUp);

    /// @notice Queue a new tier table (admin only); anyone can execute it after the timelock.
    function proposeTiers(uint256 poolId, Tier[] calldata tiers) external;

    /// @notice Drop a queued tier table (admin only).
    function cancelTiers(uint256 poolId) external;

    /// @notice Name the native pool that receives the HYPE dividends every lock of `stakeToken` earns, and the
    /// claim that pays them: `selector(exile)` on the token itself, or `selector(token, exile)` on `target` (the
    /// coin's hook). Registrars only (Monarchy factories).
    function setHarvest(address stakeToken, uint256 poolId, address target, bytes4 selector) external;

    /// @notice Claim the dividends Exile's balance of `stakeToken` earned and pay them to its harvest pool.
    function harvest(address stakeToken) external returns (uint256 amount);
}
