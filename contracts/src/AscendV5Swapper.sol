// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBuybackSwapper} from "./interfaces/IBuybackSwapper.sol";
import {IV4PoolManager, IV4UnlockCallback, V4PoolKey, V4SwapParams} from "./interfaces/IUniswapV4.sol";
import {IAscendV5Launchpad, IAscendV5EscrowFactory, IAscendV5Escrow} from "./interfaces/IAscendV5.sol";

/// @title AscendV5Swapper
/// @notice Lodestar's buyback route on Ascend v5: exact quote in (an ERC-20: WHYPE, USDC, KNTQ) for the coin, through
/// the coin's own launch pool on Uniswap v4, with the coin taken straight to `to` (the burn sink). The launchpad hook
/// takes the pool's fee in the quote inside the swap; the caller's minimum output allows for it. The pool key is
/// rebuilt from the pool's escrow (its token and quote) and checked against the pool id, so only real v5 launch
/// pools can be traded. Stateless; returns whatever quote a swap didn't spend.
contract AscendV5Swapper is IBuybackSwapper, IV4UnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_PRICE_LIMIT = 4295128740; // TickMath.MIN_SQRT_PRICE + 1
    uint160 internal constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341; // MAX - 1
    uint24 internal constant DYNAMIC_FEE = 0x800000;
    int24 internal constant TICK_SPACING = 200;

    IAscendV5Launchpad public immutable launchpad;
    IAscendV5EscrowFactory public immutable escrowFactory;
    IV4PoolManager public immutable poolManager;

    event Swapped(
        bytes32 indexed poolId, address indexed sender, uint256 quoteIn, uint256 tokensOut, address to
    );

    error OnlyPoolManager();
    error UnknownPool();
    error ZeroAmount();
    error UnexpectedDelta();
    error Slippage(uint256 out, uint256 minOut);

    constructor(IAscendV5Launchpad launchpad_) {
        launchpad = launchpad_;
        escrowFactory = IAscendV5EscrowFactory(launchpad_.escrowFactory());
        poolManager = IV4PoolManager(launchpad_.poolManager());
    }

    /// @notice The launch pool's key and which side the quote is on. Reverts `UnknownPool` for anything else.
    function keyOf(bytes32 poolId) public view returns (V4PoolKey memory key, address token, address quote) {
        address e = escrowFactory.escrowOf(poolId);
        if (e == address(0)) revert UnknownPool();
        token = IAscendV5Escrow(e).token();
        quote = IAscendV5Escrow(e).quote();
        (address c0, address c1) = token < quote ? (token, quote) : (quote, token);
        key = V4PoolKey(c0, c1, DYNAMIC_FEE, TICK_SPACING, address(launchpad));
        if (keccak256(abi.encode(key)) != poolId) revert UnknownPool();
    }

    /// @inheritdoc IBuybackSwapper
    function buyExactIn(bytes32 poolId, uint256 quoteIn, uint256 minTokenOut, address to)
        external
        nonReentrant
        returns (uint256 tokenOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        (V4PoolKey memory key, address token, address quote) = keyOf(poolId);
        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteIn);
        uint256 paid;
        (paid, tokenOut) = abi.decode(
            poolManager.unlock(abi.encode(key, quote < token, quote, token, quoteIn, minTokenOut, to)),
            (uint256, uint256)
        );
        // a price limit or the end of the curve can stop a swap early; return what the pool didn't take
        if (paid < quoteIn) IERC20(quote).safeTransfer(msg.sender, quoteIn - paid);
        emit Swapped(poolId, msg.sender, paid, tokenOut, to);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (
            V4PoolKey memory key,
            bool zeroForOne,
            address quote,
            address token,
            uint256 amountIn,
            uint256 minOut,
            address to
        ) = abi.decode(data, (V4PoolKey, bool, address, address, uint256, uint256, address));
        int256 delta = poolManager.swap(
            key,
            V4SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT
            }),
            ""
        );
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        (int128 qd, int128 td) = zeroForOne ? (a0, a1) : (a1, a0);
        if (qd > 0 || td < 0) revert UnexpectedDelta();
        uint256 paid = uint256(uint128(-qd));
        uint256 out = uint256(uint128(td));
        if (paid > amountIn) revert UnexpectedDelta();
        if (out < minOut) revert Slippage(out, minOut);
        if (paid > 0) {
            poolManager.sync(quote);
            IERC20(quote).safeTransfer(address(poolManager), paid);
            poolManager.settle();
        }
        if (out > 0) poolManager.take(token, to, out);
        return abi.encode(paid, out);
    }
}
