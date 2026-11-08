// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {INativeBuybackSwapper} from "../../src/interfaces/IBuybackSwapper.sol";
import {IV4UnlockCallback, V4PoolKey, V4SwapParams} from "../../src/interfaces/IUniswapV4.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice A launchpad hook in the shape of Boxa, Kleos and Eleos: it holds each coin's creator role and pays the
/// creator's fees in native HYPE. Works as one-step (`transferCreator`) or two-step (`propose` then `accept`).
contract MockNativeHook {
    address public constant poolManager = address(0x9999);
    mapping(address token => address) public creatorOf;
    mapping(address token => address) public pendingOf;
    mapping(address token => uint256) public owedOf;

    function launch(address token, address creator) external {
        creatorOf[token] = creator;
    }

    function accrue(address token) external payable {
        owedOf[token] += msg.value;
    }

    function claim(address token) external {
        require(msg.sender == creatorOf[token], "not creator");
        uint256 a = owedOf[token];
        owedOf[token] = 0;
        (bool ok,) = msg.sender.call{value: a}("");
        require(ok, "payout");
    }

    function transferCreator(address token, address to) external {
        require(msg.sender == creatorOf[token], "not creator");
        require(to != address(0), "zero");
        creatorOf[token] = to;
    }

    function propose(address token, address to) external {
        require(msg.sender == creatorOf[token], "not creator");
        pendingOf[token] = to;
    }

    function accept(address token) external {
        require(msg.sender == pendingOf[token] && msg.sender != address(0), "not pending");
        creatorOf[token] = msg.sender;
        pendingOf[token] = address(0);
    }
}

/// @notice An IFeeSource over `MockNativeHook`, with knobs for the cases the real adapters can't easily produce.
contract MockNativeSource is IFeeSource {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    MockNativeHook public immutable hookC;
    Handover public immutable mode;

    uint256 public holdersBps;
    address public claimTarget;
    bytes4 public claimSelector;
    uint160 public spot = uint160(1 << 96);
    uint160 public emaPrice = uint160(1 << 96);
    uint128 public liq = 1e24;
    uint256 public cost = 100;
    address public callTarget; // 0 = the hook; anything else breaks the call-target rule
    uint256 public pokes;

    constructor(MockNativeHook hook_, Handover mode_) {
        hookC = hook_;
        mode = mode_;
    }

    function set(uint256 holdersBps_, address claimTarget_, bytes4 claimSelector_) external {
        (holdersBps, claimTarget, claimSelector) = (holdersBps_, claimTarget_, claimSelector_);
    }

    function setMarket(uint160 spot_, uint160 ema_, uint128 liq_, uint256 cost_) external {
        (spot, emaPrice, liq, cost) = (spot_, ema_, liq_, cost_);
    }

    function setCallTarget(address t) external {
        callTarget = t;
    }

    function handover() external view returns (Handover) {
        return mode;
    }

    function resolve(address token, address quote) external view returns (bytes32, address, bool) {
        require(quote == address(0), "native only");
        return (keccak256(abi.encode(token)), address(hookC), false);
    }

    function desk() external pure returns (address) {
        return address(0);
    }

    function creator(address token, bytes32) external view returns (address) {
        return hookC.creatorOf(token);
    }

    function pendingCreator(address token, bytes32) external view returns (address) {
        return mode != Handover.OneStep ? hookC.pendingOf(token) : address(0);
    }

    function owed(address token, bytes32, address who) external view returns (uint256, uint256) {
        return (0, hookC.creatorOf(token) == who ? hookC.owedOf(token) : 0);
    }

    function holdersShareBps(address, bytes32) external view returns (uint256) {
        return holdersBps;
    }

    function dividendClaim(address) external view returns (address, bytes4) {
        return (claimTarget, claimSelector);
    }

    function burnSink(address) external pure returns (address) {
        return DEAD;
    }

    function swapCostBps(address, bytes32) external view returns (uint256) {
        return cost;
    }

    function prices(address, bytes32) external view returns (uint160, uint160, uint128) {
        return (spot, emaPrice, liq);
    }

    function poke(address, bytes32) external {
        ++pokes;
    }

    function collectCalls(address, bytes32, address) external pure returns (Call[] memory cs) {
        cs = new Call[](0);
    }

    function claimCalls(address token, bytes32, address router) external view returns (Call[] memory) {
        if (hookC.owedOf(token) == 0 || hookC.creatorOf(token) != router) return new Call[](0);
        return _one(abi.encodeCall(MockNativeHook.claim, (token)));
    }

    function acceptCalls(address token, bytes32, address) external view returns (Call[] memory) {
        return _one(abi.encodeCall(MockNativeHook.accept, (token)));
    }

    function transferOutCalls(address token, bytes32, address next) external view returns (Call[] memory) {
        if (mode != Handover.OneStep) return _one(abi.encodeCall(MockNativeHook.propose, (token, next)));
        if (next == address(0)) return new Call[](0);
        return _one(abi.encodeCall(MockNativeHook.transferCreator, (token, next)));
    }

    function _one(bytes memory data) internal view returns (Call[] memory cs) {
        cs = new Call[](1);
        cs[0] = Call(callTarget == address(0) ? address(hookC) : callTarget, data);
    }
}

/// @notice A native buyback route at a fixed price: `rate` tokens (1e18 = one per wei) for each wei of HYPE,
/// minted to `to`. `shortBps` pays that much less than promised, to test the router's own output check.
contract MockNativeSwapper is INativeBuybackSwapper {
    MockERC20 public immutable token;
    uint256 public rate = 1e18;
    uint256 public shortBps;

    constructor(MockERC20 token_) {
        token = token_;
    }

    function setShort(uint256 bps) external {
        shortBps = bps;
    }

    function buyExactIn(bytes32, uint256 quoteIn, uint256 minTokenOut, address to)
        external
        payable
        returns (uint256 out)
    {
        require(msg.value == quoteIn, "value");
        out = quoteIn * rate / 1e18;
        require(out >= minTokenOut, "slippage");
        out -= out * shortBps / 10_000;
        token.mint(to, out);
    }
}

/// @notice A coin that pays holders HYPE dividends inside itself, Eleos and Kleos style: `claimFor(holder)` pushes a
/// holder's dividends to the holder (anyone may call), `claimRewards(holder)` pays them only when the holder calls.
/// ElysPump style, `claim()` pays the caller's.
contract MockDividendToken is MockERC20 {
    mapping(address => uint256) public dividendOf;
    bool public broken;

    constructor() MockERC20("Dividend", "DIV", 18) {}

    function credit(address holder) external payable {
        dividendOf[holder] += msg.value;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function claimFor(address holder) external returns (uint256 a) {
        return _pay(holder);
    }

    function claimRewards(address holder) external {
        require(msg.sender == holder, "holder only");
        _pay(holder);
    }

    function claim() external returns (uint256) {
        return _pay(msg.sender);
    }

    function _pay(address holder) internal returns (uint256 a) {
        require(!broken, "paused");
        a = dividendOf[holder];
        dividendOf[holder] = 0;
        (bool ok,) = holder.call{value: a}("");
        require(ok, "payout");
    }
}

/// @notice A hook that keeps holder dividends itself, Boxa style: the holder calls `claimRewards(token, recipient)`.
contract MockDividendHook {
    mapping(address token => mapping(address holder => uint256)) public dividendOf;

    function credit(address token, address holder) external payable {
        dividendOf[token][holder] += msg.value;
    }

    function claimRewards(address token, address recipient) external {
        uint256 a = dividendOf[token][msg.sender];
        dividendOf[token][msg.sender] = 0;
        (bool ok,) = recipient.call{value: a}("");
        require(ok, "payout");
    }
}

/// @notice Refuses HYPE.
contract NoReceive {}

/// @notice A Uniswap v4 PoolManager stand-in: pool state in the StateLibrary layout behind `extsload`, and an
/// exact-in HYPE-for-token swap at a fixed rate (tokens per wei, 1e18 scale) less a fee on the input.
contract MockV4PoolManager {
    mapping(bytes32 => bytes32) internal _store;
    MockERC20 public immutable token;
    uint256 public rate = 1e18;
    uint256 public feeBps;
    uint256 public fillBps = 10_000; // how much of the input a swap takes (a price limit can stop it early)
    uint256 internal _owed;

    constructor(MockERC20 token_) {
        token = token_;
    }

    function setPool(bytes32 id, uint160 sqrtPriceX96, int24 tick, uint24 lpFee, uint128 liquidity) external {
        bytes32 s = keccak256(abi.encodePacked(id, bytes32(uint256(6))));
        _store[s] = bytes32(
            uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160) | (uint256(lpFee) << 208)
        );
        _store[bytes32(uint256(s) + 3)] = bytes32(uint256(liquidity));
    }

    function setSwap(uint256 rate_, uint256 feeBps_, uint256 fillBps_) external {
        (rate, feeBps, fillBps) = (rate_, feeBps_, fillBps_);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _store[slot];
    }

    function unlock(bytes calldata data) external returns (bytes memory r) {
        r = IV4UnlockCallback(msg.sender).unlockCallback(data);
        require(_owed == 0, "not settled");
    }

    function swap(V4PoolKey memory, V4SwapParams memory p, bytes calldata) external returns (int256) {
        require(p.zeroForOne && p.amountSpecified < 0, "exact HYPE in only");
        uint256 spent = uint256(-p.amountSpecified) * fillBps / 10_000;
        uint256 out = (spent - spent * feeBps / 10_000) * rate / 1e18;
        _owed += spent;
        return int256((uint256(uint128(-int128(int256(spent)))) << 128) | uint256(uint128(out)));
    }

    function sync(address) external {}

    function settle() external payable returns (uint256) {
        _owed -= msg.value;
        return msg.value;
    }

    function take(address, address to, uint256 amount) external {
        token.mint(to, amount);
    }
}
