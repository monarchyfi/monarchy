// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBuybackSwapper {
    /// @notice Pull `quoteIn` of the pool's quote asset from the caller and buy the pool's token.
    function buyExactIn(bytes32 poolId, uint256 quoteIn, uint256 minTokenOut, address to)
        external
        returns (uint256 tokenOut);
}

/// @notice The same call for pools quoted in native HYPE: the caller sends `quoteIn` as msg.value and gets back
/// whatever the swap didn't spend.
interface INativeBuybackSwapper {
    function buyExactIn(bytes32 poolId, uint256 quoteIn, uint256 minTokenOut, address to)
        external
        payable
        returns (uint256 tokenOut);
}
