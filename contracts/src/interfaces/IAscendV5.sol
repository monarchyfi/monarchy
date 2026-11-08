// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The subset of Ascend's v5 launchpad (Elysium mainnet, Uniswap v4) that Monarchy uses. The launchpad is
/// every launch pool's hook; it takes each pool's fee in the quote and books it to the pool's CreatorEscrow.
/// Source: the release's ABIs at ascendlaunch.xyz/abis/ascend-v5-99901-422319.json.
interface IAscendV5Launchpad {
    /// @notice Books the pool's accrued fees to its escrow. Permissionless.
    function collect(bytes32 poolId) external returns (uint256);
    /// @notice Pays the escrow what it is owed, in the quote. Permissionless.
    function claim(bytes32 poolId) external;
    /// @notice The pool's fee in pips (1e6 = 100%): the creator's choice of 1% to 10% plus any builder fee, fixed.
    function currentFee(bytes32 poolId) external view returns (uint24);
    function emaSqrtPrice(bytes32 poolId) external view returns (uint160);
    function poolCreator(bytes32 poolId) external view returns (address);
    function poolTokenIs0(bytes32 poolId) external view returns (bool);
    function poolManager() external view returns (address);
    function escrowFactory() external view returns (address);
    function launchFeeWindowSeconds() external view returns (uint256);
}

interface IAscendV5EscrowFactory {
    function escrowOf(bytes32 poolId) external view returns (address);
    function launchpad() external view returns (address);
}

/// @notice A pool's creator role on Ascend v5. Each arrival of fees is split by the RuleSet the pool launched with;
/// the creator's part is credited to `recipient` (part of it held until the coin graduates) and paid out by
/// `claim(account)`, which anyone may call and which pays only `account`. The recipient changes in two steps:
/// the recipient proposes, and the proposed address accepts once `recipientReadyAt` has passed (48 hours).
interface IAscendV5Escrow {
    function recipient() external view returns (address);
    function pendingRecipient() external view returns (address);
    function recipientReadyAt() external view returns (uint40);
    function proposeRecipient(address next) external;
    function acceptRecipient() external;
    function claim(address account) external returns (uint256);
    function claimable(address account) external view returns (uint256);
    function token() external view returns (address);
    function quote() external view returns (address);
    function poolId() external view returns (bytes32);
    function launchpad() external view returns (address);
    function factory() external view returns (address);
    /// @notice 0 before graduation; held creator fees unlock when it moves on.
    function phase() external view returns (uint8);
    function held() external view returns (uint256);
    function deadline() external view returns (uint40);
    /// @notice address(0) when the pool did not opt in to community takeovers.
    function ctoRegistry() external view returns (address);
}

/// @notice Ascend's seat contract, the recipient of Holder Rewards, Buyback and Custom mix coins: its split is fixed at
/// launch and it never proposes a new recipient. `escrow()` names the pool's escrow, which is how a site tells a seat
/// from a creator's own wallet or multisig.
interface IAscendV5Seat {
    function escrow() external view returns (address);
}
