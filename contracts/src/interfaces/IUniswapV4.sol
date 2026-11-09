// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice The subset of Uniswap v4's PoolManager that Monarchy uses, with v4's own ABI. Volta, Montra, ElysPump,
/// Boxa and Kleos all run the official PoolManager code on Elysium (some share one deployment, some have their own).
/// Currencies and hooks are plain addresses here (v4 wraps them in user-defined types, which encode the same), and
/// address(0) is native HYPE. A pool's id is `keccak256(abi.encode(key))`.
struct V4PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct V4SwapParams {
    bool zeroForOne;
    int256 amountSpecified; // negative = exact input
    uint160 sqrtPriceLimitX96;
}

interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @return swapDelta amount0 in the high 128 bits, amount1 in the low 128 bits; negative = owed by the caller
    function swap(V4PoolKey memory key, V4SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);

    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32 value);
}

interface IV4UnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
