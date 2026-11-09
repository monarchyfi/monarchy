// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {V4FeeSource} from "./V4FeeSource.sol";
import {V4PriceObserver} from "../V4PriceObserver.sol";
import {V4PoolKey} from "../interfaces/IUniswapV4.sol";
import {
    IVoltaPositionManager,
    IVoltaCreatorNFT,
    IVoltaFeeEscrow,
    IVoltaToken
} from "../interfaces/ILaunchpadHooks.sol";

/// @title VoltaFeeSource
/// @notice Adapter for Volta (volta.family), a fork of Flaunch on Elysium's official Uniswap v4 pool manager. Each
/// coin trades in one pool whose hook is Volta's PositionManager. The hook takes the coin's swap fee (1% to 5%)
/// in the quote, keeps 30% for the protocol and splits the rest by the shares the coin launched with: the creator's
/// share, the buyback share (Volta buys the coin and burns it) and the holders' share (paid by Volta's fee
/// executor to wallets holding at least 0.1% of the supply; contracts, Exile included, are left out).
///
/// The creator role is an NFT, one per launch, and moves with an ERC-721 transfer: one step, at once. The creator's
/// share is credited, as the hook distributes a pool's fees, to whoever holds the NFT at that moment, in Volta's
/// fee escrow, by address and across every coin that address has held the NFT of (so fees credited before a
/// handover stay with the old holder: claim them first). The holder withdraws with
/// `withdrawFees(HYPE, to, false)`, paid from its own balance.
///
/// So the router keeps two call targets: the creator NFT, as its `hook` (the contract that holds the role), and the
/// escrow, as its `payer`. Version 1 supports native HYPE coins only (some coins are quoted in KNTQ or $VOLTA), and
/// a coin whose creator share is 0 has nothing to route, so it can't be activated (`NoCreatorShare`).
contract VoltaFeeSource is V4FeeSource {
    uint8 public constant KIND_POSITION_MANAGER = 1;

    error NoCreatorShare();
    error UnknownCoin();

    constructor(V4PriceObserver observer_, address owner_, address[] memory hooks_, uint8[] memory kinds_)
        V4FeeSource(observer_, owner_, hooks_, kinds_)
    {}

    function handover() external pure returns (Handover) {
        return Handover.OneStep;
    }

    /// @notice The registered PositionManager a coin trades through. A Volta coin names its creator NFT
    /// (`flaunch()`), and the NFT its PositionManager; both must point back at each other and the NFT must have
    /// launched this very coin, so a lookalike token can't borrow a real pool.
    function hookOf(address token) public view override returns (address hook, HookInfo memory info) {
        address nft = _nftOf(token);
        try IVoltaCreatorNFT(nft).positionManager() returns (address pm) {
            hook = pm;
        } catch {
            revert UnsupportedHook();
        }
        info = hooks[hook];
        if (info.kind == 0) revert UnsupportedHook();
        if (IVoltaPositionManager(hook).flaunchContract() != nft) revert UnsupportedHook();
        if (_idOf(nft, token) == 0) revert UnknownCoin();
    }

    /// @dev The router's `hook` is the creator NFT, which holds the role; the base checks the pool on the
    /// PositionManager. On top: the coin must pay its creator something.
    function resolve(address token, address quote)
        public
        view
        override
        returns (bytes32 poolId, address hook, bool tokenIs0)
    {
        (poolId,, tokenIs0) = super.resolve(token, quote);
        if (creatorShareBps(token) == 0) revert NoCreatorShare();
        hook = _nftOf(token);
    }

    /// @notice Volta's fee escrow for native HYPE, where the creator's share waits for the NFT's holder.
    function payer(address token) public view override returns (address) {
        (address pm,) = hookOf(token);
        return IVoltaPositionManager(pm).pairedTokenFeeEscrow(_poolId(token));
    }

    /// @notice The NFT that is the coin's creator role, and its id.
    function creatorNft(address token) public view returns (address nft, uint256 id) {
        hookOf(token);
        nft = _nftOf(token);
        id = _idOf(nft, token);
    }

    function creator(address token, bytes32) external view returns (address) {
        (address nft, uint256 id) = creatorNft(token);
        return IVoltaCreatorNFT(nft).ownerOf(id);
    }

    function pendingCreator(address, bytes32) external pure returns (address) {
        return address(0);
    }

    function owed(address token, bytes32, address who) external view returns (uint256, uint256) {
        return (0, IVoltaFeeEscrow(payer(token)).balances(who, address(0)));
    }

    /// @dev Volta pays the holders' share to wallets only, so coins locked in Exile earn none of it and there is
    /// nothing for Exile to harvest.
    function holdersShareBps(address, bytes32) external pure returns (uint256) {
        return 0;
    }

    function dividendClaim(address) external pure returns (address, bytes4) {
        return (address(0), bytes4(0));
    }

    /// @notice The coin's split of the fee after the protocol's 30%, in bps: creator, buyback and burn, holders.
    function split(address token) public view returns (uint256 creatorBps, uint256 buybackBps, uint256 holdersBps) {
        (address pm,) = hookOf(token);
        IVoltaPositionManager.CreatorSplit memory s = IVoltaPositionManager(pm).poolFees(_poolId(token)).creatorSplit;
        return (s.creator, s.buyback, s.holders);
    }

    /// @notice The creator's share of the coin's fee after the protocol's 30%, in bps (0 = it can't be activated).
    function creatorShareBps(address token) public view returns (uint256 bps) {
        (bps,,) = split(token);
    }

    /// @dev The pool's LP fee is 0 (checked in `_poolKey`); a buy pays the coin's swap fee, or its anti-snipe fee in
    /// the first minutes after launch.
    function swapCostBps(address token, bytes32) external view returns (uint256) {
        (address pm,) = hookOf(token);
        return IVoltaPositionManager(pm).currentSwapFee(_poolId(token), true);
    }

    function collectCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    function claimCalls(address token, bytes32, address router) external view returns (Call[] memory) {
        address escrow = payer(token);
        if (IVoltaFeeEscrow(escrow).balances(router, address(0)) == 0) return _none();
        return _one(escrow, abi.encodeCall(IVoltaFeeEscrow.withdrawFees, (address(0), router, false)));
    }

    function acceptCalls(address, bytes32, address) external pure returns (Call[] memory) {
        return _none();
    }

    /// @dev The NFT moves from whoever holds it now: the router, for its own coin or for a coin's role that
    /// landed on it by mistake.
    function transferOutCalls(address token, bytes32, address next) external view returns (Call[] memory) {
        if (next == address(0)) return _none(); // nothing is ever pending on a one-step launchpad
        (address nft, uint256 id) = creatorNft(token);
        address from = IVoltaCreatorNFT(nft).ownerOf(id);
        return _one(nft, abi.encodeCall(IVoltaCreatorNFT.transferFrom, (from, next, id)));
    }

    function _nftOf(address token) internal view returns (address nft) {
        try IVoltaToken(token).flaunch() returns (address n) {
            nft = n;
        } catch {
            revert UnsupportedHook();
        }
        if (nft.code.length == 0) revert UnsupportedHook();
    }

    /// @dev The coin's NFT id, or 0 when the NFT didn't launch it.
    function _idOf(address nft, address token) internal view returns (uint256 id) {
        id = IVoltaCreatorNFT(nft).tokenId(token);
        if (id != 0 && IVoltaCreatorNFT(nft).memecoin(id) != token) id = 0;
    }

    function _poolId(address token) internal view returns (bytes32) {
        return keccak256(abi.encode(poolKey(token)));
    }

    function _maxKind() internal pure override returns (uint8) {
        return KIND_POSITION_MANAGER;
    }

    function _poolKey(address token, address hook, uint8)
        internal
        view
        override
        returns (V4PoolKey memory key)
    {
        key = IVoltaPositionManager(hook).poolKey(token);
        if (key.fee != 0) revert PoolMismatch(); // swap cost assumes no LP fee on top of the coin's fee
    }
}
