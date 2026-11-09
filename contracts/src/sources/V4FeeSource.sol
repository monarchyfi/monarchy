// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IFeeSource} from "../interfaces/IFeeSource.sol";
import {IV4PoolManager, V4PoolKey} from "../interfaces/IUniswapV4.sol";
import {V4State} from "../libraries/V4State.sol";
import {V4PriceObserver} from "../V4PriceObserver.sol";

interface IHasHook {
    function hook() external view returns (address);
}

interface IHasPoolManager {
    function poolManager() external view returns (address);
}

/// @title V4FeeSource
/// @notice Shared base for the adapters of launchpads built as Uniswap v4 hooks on Elysium (Volta, ElysPump, Boxa,
/// Kleos, Montra).
/// Every coin there trades in one pool, native HYPE against the coin, so this base only supports pools whose
/// currency0 is native HYPE and whose currency1 is the coin; fees arrive as native HYPE.
///
/// A launchpad ships new hook generations from time to time. Each adapter keeps a registry of the hooks it knows,
/// with a kind that picks the calls for that generation and the pool manager the hook runs on (read from the
/// hook). The owner (the same multisig as the factory) can add a hook, never change or remove one, so an entry a
/// router relies on can't move under it; a router also stores its hook at initialize and only ever calls that one.
/// A coin whose hook isn't registered can't be activated (`UnsupportedHook`).
abstract contract V4FeeSource is IFeeSource {
    /// @dev The burn address these launchpads count as burned and exclude from dividends.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct HookInfo {
        uint8 kind; // 0 = unknown
        address poolManager;
    }

    V4PriceObserver public immutable observer;
    address public owner;
    address public pendingOwner;
    mapping(address hook => HookInfo) public hooks;
    address[] public hookList;

    event HookAdded(address indexed hook, uint8 kind, address poolManager);
    event OwnerTransferStarted(address indexed next);
    event OwnerTransferred(address indexed previous, address indexed next);

    error OnlyOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error UnsupportedHook();
    error KnownHook();
    error BadKind();
    error QuoteUnsupported();
    error PoolMismatch();

    constructor(V4PriceObserver observer_, address owner_, address[] memory hooks_, uint8[] memory kinds_) {
        if (owner_ == address(0) || address(observer_) == address(0)) revert ZeroAddress();
        if (hooks_.length != kinds_.length) revert BadKind();
        observer = observer_;
        owner = owner_;
        emit OwnerTransferred(address(0), owner_);
        for (uint256 i; i < hooks_.length; ++i) {
            _addHook(hooks_[i], kinds_[i]);
        }
    }

    // ---------------------------------------------------------------- registry (owner)

    /// @notice Register a new hook generation of this launchpad. Add-only: an entry can never change or go away.
    function addHook(address hook, uint8 kind) external {
        if (msg.sender != owner) revert OnlyOwner();
        _addHook(hook, kind);
    }

    function hookCount() external view returns (uint256) {
        return hookList.length;
    }

    function transferOwner(address next) external {
        if (msg.sender != owner) revert OnlyOwner();
        pendingOwner = next;
        emit OwnerTransferStarted(next);
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnerTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _addHook(address hook, uint8 kind) internal {
        if (hook == address(0)) revert ZeroAddress();
        if (hooks[hook].kind != 0) revert KnownHook();
        if (kind == 0 || kind > _maxKind()) revert BadKind();
        address pm = IHasPoolManager(hook).poolManager();
        if (pm == address(0)) revert ZeroAddress();
        hooks[hook] = HookInfo(kind, pm);
        hookList.push(hook);
        emit HookAdded(hook, kind, pm);
    }

    // ---------------------------------------------------------------- shared views

    /// @notice The registered hook a coin trades through. Reverts `UnsupportedHook` for anything else.
    function hookOf(address token) public view virtual returns (address hook, HookInfo memory info) {
        try IHasHook(token).hook() returns (address h) {
            hook = h;
        } catch {
            revert UnsupportedHook();
        }
        info = hooks[hook];
        if (info.kind == 0) revert UnsupportedHook();
    }

    /// @notice The coin's pool key on its hook's pool manager.
    function poolKey(address token) public view returns (V4PoolKey memory key) {
        (address hook, HookInfo memory info) = hookOf(token);
        key = _poolKey(token, hook, info.kind);
    }

    function resolve(address token, address quote)
        public
        view
        virtual
        returns (bytes32 poolId, address hook, bool tokenIs0)
    {
        if (quote != address(0)) revert QuoteUnsupported();
        HookInfo memory info;
        (hook, info) = hookOf(token);
        V4PoolKey memory key = _poolKey(token, hook, info.kind);
        // native HYPE against the coin only: a pool quoted in another token pays fees in that token
        if (key.currency0 != address(0) || key.currency1 != token) revert QuoteUnsupported();
        if (key.hooks != hook) revert PoolMismatch();
        poolId = keccak256(abi.encode(key));
        tokenIs0 = false;
    }

    function desk() external pure returns (address) {
        return address(0);
    }

    /// @dev The hook that holds the role pays its fees, except where an adapter says otherwise (Volta).
    function payer(address) external view virtual returns (address) {
        return address(0);
    }

    function burnSink(address) external pure returns (address) {
        return DEAD;
    }

    /// @dev Spot and liquidity straight from the pool manager's storage; the EMA from Monarchy's observer.
    function prices(address token, bytes32 poolId)
        external
        view
        returns (uint160 spot, uint160 ema, uint128 liquidity)
    {
        (, HookInfo memory info) = hookOf(token);
        IV4PoolManager pm = IV4PoolManager(info.poolManager);
        (spot,,) = V4State.slot0(pm, poolId);
        liquidity = V4State.liquidity(pm, poolId);
        ema = observer.ema(address(pm), poolId);
    }

    function poke(address token, bytes32) external {
        (address hook, HookInfo memory info) = hookOf(token);
        observer.poke(info.poolManager, _poolKey(token, hook, info.kind));
    }

    // ---------------------------------------------------------------- for the launchpads

    function _maxKind() internal pure virtual returns (uint8);

    function _poolKey(address token, address hook, uint8 kind)
        internal
        view
        virtual
        returns (V4PoolKey memory);

    /// @dev The hook a router stores is the only call target, so every plan here targets it.
    function _hookOfChecked(address token) internal view returns (address hook, uint8 kind) {
        HookInfo memory info;
        (hook, info) = hookOf(token);
        kind = info.kind;
    }

    function _none() internal pure returns (Call[] memory cs) {
        cs = new Call[](0);
    }

    function _one(address target, bytes memory data) internal pure returns (Call[] memory cs) {
        cs = new Call[](1);
        cs[0] = Call(target, data);
    }
}
