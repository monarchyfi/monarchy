// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IV4PoolManager, V4PoolKey} from "../interfaces/IUniswapV4.sol";

/// @notice Reads a Uniswap v4 pool's price and active liquidity straight from the PoolManager's storage, the way
/// v4-core's StateLibrary does: the pools mapping sits at slot 6, each pool's slot0 is the first word of its state
/// and its liquidity the fourth. slot0 packs sqrtPriceX96 (160 bits), tick (24), protocolFee (24), lpFee (24).
library V4State {
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    function id(V4PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function stateSlot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId, POOLS_SLOT));
    }

    function slot0(IV4PoolManager pm, bytes32 poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 lpFee)
    {
        uint256 data = uint256(pm.extsload(stateSlot(poolId)));
        sqrtPriceX96 = uint160(data);
        tick = int24(int256(data >> 160));
        lpFee = uint24(data >> 208);
    }

    function liquidity(IV4PoolManager pm, bytes32 poolId) internal view returns (uint128) {
        return uint128(uint256(pm.extsload(bytes32(uint256(stateSlot(poolId)) + LIQUIDITY_OFFSET))));
    }
}
