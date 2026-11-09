// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILodestar {
    /// @notice How a Lodestar routes its creator fees. The quote side splits by basis points that sum to
    /// 10_000; the token side is either burned or paid to Exile lockers in full.
    struct Config {
        uint16 burnBps; // buy back the token and burn it
        uint16 holdersBps; // Exile holder rewards
        uint16 treasuryBps; // Team Treasury, streamed through Sandfall
        address swapper; // buyback route; 0 = keep the buyback share in reserve
        uint16 maxSlippageBps; // vs the stricter of the EMA price and spot, on top of the pool's fee or tax
        bool tokenToHolders; // token-side fees: false = burn them all, true = all of them to Exile lockers
    }

    struct InitParams {
        address source; // the launchpad's IFeeSource adapter
        address hook; // the contract that holds the creator role; with `payer`, the only addresses the router calls
        address payer; // the contract that pays the role's fees when it isn't `hook` (Volta), else address(0)
        address desk; // the launchpad's listing desk, or address(0)
        address exile;
        address sandfall;
        bytes32 poolId;
        address token;
        address quote; // address(0) = native HYPE
        bool tokenIs0;
        address burnSink;
        uint256 exilePoolId;
        uint256 treasuryStreamId;
        address steward;
        Config config;
    }

    function initialize(InitParams calldata p) external;
    function acceptCreator() external;
    function enrollListing(uint256 cap) external;
    function lockCreatorRole(uint64 until) external;
    function distribute() external;
    function steward() external view returns (address);
    function upgradeTarget() external view returns (address);
    function releaseForeignRole(address foreignToken, address to) external;
}
