// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INativeBuybackSwapper} from "./interfaces/IBuybackSwapper.sol";
import {IV4PoolManager, IV4UnlockCallback, V4PoolKey, V4SwapParams} from "./interfaces/IUniswapV4.sol";
import {V4PriceObserver} from "./V4PriceObserver.sol";

/// @title V4Swapper
/// @notice Lodestar's buyback route on one Uniswap v4 PoolManager (one swapper per launchpad deployment), for
/// pools quoted in native HYPE. It swaps exact HYPE in for the coin and takes the coin straight to `to` (the
/// burn address), so the router never holds the coin and a coin's max-wallet or launch limits can't block it.
/// The launchpad hooks take their tax as part of the swap; the caller's floor allows for it. Pool keys come from
/// the price observer, which records them on the first poke. Stateless; holds nothing between calls and returns
/// whatever HYPE a swap didn't spend.
contract V4Swapper is INativeBuybackSwapper, IV4UnlockCallback, ReentrancyGuard {
    /// @dev TickMath.MIN_SQRT_PRICE + 1: no price limit when selling currency0 for currency1.
    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740;

    IV4PoolManager public immutable poolManager;
    V4PriceObserver public immutable observer;

    event Swapped(
        bytes32 indexed poolId, address indexed sender, uint256 hypeIn, uint256 tokensOut, address to
    );

    error OnlyPoolManager();
    error UnknownPool();
    error NotNativePool();
    error WrongValue();
    error ZeroAmount();
    error UnexpectedDelta();
    error Slippage(uint256 out, uint256 minOut);
    error RefundFailed();

    constructor(IV4PoolManager poolManager_, V4PriceObserver observer_) {
        poolManager = poolManager_;
        observer = observer_;
    }

    /// @inheritdoc INativeBuybackSwapper
    function buyExactIn(bytes32 poolId, uint256 quoteIn, uint256 minTokenOut, address to)
        external
        payable
        nonReentrant
        returns (uint256 tokenOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        if (msg.value != quoteIn) revert WrongValue();
        V4PoolKey memory key = observer.keyOf(address(poolManager), poolId);
        if (key.currency1 == address(0)) revert UnknownPool();
        if (key.currency0 != address(0)) revert NotNativePool();
        uint256 paid;
        (paid, tokenOut) =
            abi.decode(poolManager.unlock(abi.encode(key, quoteIn, minTokenOut, to)), (uint256, uint256));
        if (paid < quoteIn) {
            // a price limit can stop a swap early; return what the pool didn't take
            (bool ok,) = msg.sender.call{value: quoteIn - paid}("");
            if (!ok) revert RefundFailed();
        }
        emit Swapped(poolId, msg.sender, paid, tokenOut, to);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (V4PoolKey memory key, uint256 amountIn, uint256 minOut, address to) =
            abi.decode(data, (V4PoolKey, uint256, uint256, address));
        int256 delta = poolManager.swap(
            key,
            V4SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        if (a0 > 0 || a1 < 0) revert UnexpectedDelta();
        uint256 paid = uint256(uint128(-a0));
        uint256 out = uint256(uint128(a1));
        if (paid > amountIn) revert UnexpectedDelta();
        if (out < minOut) revert Slippage(out, minOut);
        // native HYPE settles by value; no sync needed for address(0)
        if (paid > 0) poolManager.settle{value: paid}();
        if (out > 0) poolManager.take(key.currency1, to, out);
        return abi.encode(paid, out);
    }
}
