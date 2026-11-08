// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {AscendV5Swapper} from "../../src/AscendV5Swapper.sol";
import {AscendV5FeeSource} from "../../src/sources/AscendV5FeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {IAscendV5Launchpad, IAscendV5Escrow} from "../../src/interfaces/IAscendV5.sol";

interface IWHYPE {
    function deposit() external payable;
}

interface IEscrowLifecycle {
    function startHold() external;
    function graduate() external;
    function poke() external;
    function settle() external;
}

interface ICtoRegistryV5 {
    function owner() external view returns (address);
    function NOTICE() external view returns (uint256);
    function submitRequest(bytes32 poolId, string calldata evidence) external returns (uint256 id);
    function review(uint256 id, bool approve, string calldata decision) external;
    function accept(uint256 id) external;
}

/// @notice Lodestar on Ascend v5 (ascendlaunch.xyz) against the real launchpad, escrows and pools on an Elysium
/// mainnet fork. Coins are Vanilla launches (their escrow pays a wallet), quoted in WHYPE.
contract AscendV5ForkTest is ForkBase {
    address internal constant LAUNCHPAD = 0xe0dEF4221b9840a610D4e7d55812a79A6431a8eC;
    address internal constant ESCROW_FACTORY = 0x63f6a8A8d0257c0363251a50cdE8A8b1046e4d19;
    address internal constant POOL_MANAGER = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;
    address internal constant BURN_SINK = 0x9F0b0e3B362937b07Cd1E869b50687961e0c7741;
    address internal constant WHYPE = 0xbA876237B0F021A6c6D852d6c26E107997cC5E81;

    // 1% fee, the coin sorts after WHYPE (currency1)
    address internal constant COIN_1 = 0xFae8A55Ed42E18F00CB70e46476402e630296C32;
    // 3% fee, the coin sorts before WHYPE (currency0)
    address internal constant COIN_3 = 0x086f8850FBC3101c4Bdc6932c3D5f639cb34D2DF;
    address internal constant ESCROW_3 = 0x5d14d7391A46BEc222e88889b3e4d7F8B98C93f3;
    // 10% fee
    address internal constant COIN_10 = 0xB8c3116D0565F11CAa9474F5DB7c8dC991B9F462;

    AscendV5FeeSource internal source;
    AscendV5Swapper internal v5swapper;
    LodestarFactory internal factory;

    function setUp() public {
        if (!_fork()) return;
        source = new AscendV5FeeSource(IAscendV5Launchpad(LAUNCHPAD), BURN_SINK);
        v5swapper = new AscendV5Swapper(IAscendV5Launchpad(LAUNCHPAD));
        factory = _factory(IFeeSource(address(source)));
        vm.prank(trader);
        IWHYPE(WHYPE).deposit{value: 5_000 ether}();
        vm.prank(trader);
        IERC20(WHYPE).approve(address(v5swapper), type(uint256).max);
    }

    function _escrow(address coin) internal view returns (IAscendV5Escrow) {
        (, address hook,) = source.resolve(coin, WHYPE);
        return IAscendV5Escrow(hook);
    }

    function _v5params(address coin, address swapper)
        internal
        view
        returns (LodestarFactory.DeployParams memory p)
    {
        p = _params(coin, swapper);
        p.quote = WHYPE;
    }

    /// @dev Propose the predicted router, deploy it (no accept yet), wait out the escrow's 48 hours, accept.
    function _activate(address coin, address swapper) internal returns (Lodestar l) {
        IAscendV5Escrow e = _escrow(coin);
        address dev = e.recipient();
        (address predicted,) = factory.predict(coin, WHYPE);
        vm.prank(dev);
        e.proposeRecipient(predicted);
        vm.prank(dev);
        l = Lodestar(payable(factory.deploy(_v5params(coin, swapper))));
        assertEq(address(l), predicted);
        assertFalse(l.isCreator(), "not before the wait");
        skip(2 days);
        l.acceptCreator();
        assertTrue(l.isCreator(), "the router is the escrow's recipient");
        assertEq(e.pendingRecipient(), address(0));
    }

    function _buy(address coin, uint256 whypeIn, address to) internal returns (uint256 out) {
        (bytes32 id,,) = source.resolve(coin, WHYPE);
        vm.prank(trader);
        out = v5swapper.buyExactIn(id, whypeIn, 0, to);
    }

    function _trade(address coin, uint256 each, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _buy(coin, each, locker);
            skip(2 minutes);
        }
        skip(20 minutes);
    }

    function test_resolveAndViews() public view {
        (bytes32 id, address hook, bool tokenIs0) = source.resolve(COIN_3, WHYPE);
        assertEq(hook, ESCROW_3);
        assertTrue(tokenIs0);
        assertEq(IAscendV5Escrow(hook).poolId(), id);
        assertEq(source.swapCostBps(COIN_3, id), 300);
        assertEq(source.burnSink(COIN_3), BURN_SINK);
        assertEq(uint8(source.handover()), uint8(IFeeSource.Handover.TwoStepDelayed));
        (uint160 spot, uint160 ema, uint128 liq) = source.prices(COIN_3, id);
        assertGt(spot, 0);
        assertGt(ema, 0);
        assertGt(liq, 0);
        (,, bool tokenIs0b) = source.resolve(COIN_1, WHYPE);
        assertFalse(tokenIs0b);
        (bytes32 id10,,) = source.resolve(COIN_10, WHYPE);
        assertEq(source.swapCostBps(COIN_10, id10), 1000);
    }

    function test_nativeAndUnknownPairsRefused() public {
        vm.expectRevert(AscendV5FeeSource.QuoteUnsupported.selector);
        source.resolve(COIN_3, address(0));
        vm.expectRevert(AscendV5FeeSource.UnknownPool.selector);
        source.resolve(COIN_3, address(0xB0B));
    }

    function test_proposalRequiredFirst() public {
        address dev = _escrow(COIN_3).recipient();
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.TransferCreatorFirst.selector);
        factory.deploy(_v5params(COIN_3, address(0)));
    }

    function test_acceptWaitsForTheEscrowsDelay() public {
        IAscendV5Escrow e = _escrow(COIN_3);
        address dev = e.recipient();
        (address predicted,) = factory.predict(COIN_3, WHYPE);
        vm.prank(dev);
        e.proposeRecipient(predicted);
        LodestarFactory.DeployParams memory p = _v5params(COIN_3, address(0));
        p.creatorLockUntil = type(uint64).max;
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory.deploy(p)));
        assertEq(l.creatorLockedUntil(), type(uint64).max, "locked while the hand-off to it is pending");
        vm.expectRevert();
        l.acceptCreator();
        skip(2 days);
        l.acceptCreator();
        assertTrue(l.isCreator());
        // the lock now holds: the steward can't hand the role on
        vm.prank(l.steward());
        vm.expectRevert(Lodestar.CreatorRoleIsLocked.selector);
        l.transferCreatorOut(makeAddr("elsewhere"));
    }

    /// @dev Credits earned before the hand-off stay with the old recipient; later ones are routed.
    function test_claimAndDistribute() public {
        IAscendV5Escrow e = _escrow(COIN_1);
        address dev = e.recipient();
        Lodestar l = _activate(COIN_1, address(0));
        uint256 devCredits = e.claimable(dev);
        _trade(COIN_1, 20 ether, 10);
        uint256 lockerCoins = IERC20(COIN_1).balanceOf(locker);
        _lock(COIN_1, l.exilePoolId(), lockerCoins);

        uint256 before = IERC20(WHYPE).balanceOf(address(l));
        l.distribute();
        uint256 routed = l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve();
        assertGt(routed, 0, "the escrow paid the router");
        assertEq(before, 0);
        assertEq(e.claimable(address(l)), 0);
        assertGe(e.claimable(dev), devCredits, "the dev keeps what they earned before");
        assertEq(l.totalHoldersQuote(), routed * HOLDERS_BPS / 10_000);
        assertEq(IERC20(WHYPE).balanceOf(address(l)), l.buybackReserve());

        skip(3 days);
        uint256[] memory ids = exile.lockIdsOf(locker);
        uint256 got = IERC20(WHYPE).balanceOf(locker);
        vm.prank(locker);
        exile.claimRewards(ids[0]);
        assertApproxEqRel(IERC20(WHYPE).balanceOf(locker) - got, l.totalHoldersQuote(), 1e15);
    }

    /// @dev The escrow refuses to pay out with less than about 600,000 gas left (InsufficientCollectGas), and
    /// distribute carries on without the payout. A wallet's estimate finds that cheaper path, so the keeper and the
    /// site send Ascend distributes with at least 2,000,000 gas. Nothing is lost on the short path: the credit waits.
    function test_distributeNeedsGasForTheEscrowPayout() public {
        IAscendV5Escrow e = _escrow(COIN_3);
        Lodestar l = _activate(COIN_3, address(0));
        _trade(COIN_3, 20 ether, 5);
        (bytes32 id,,) = source.resolve(COIN_3, WHYPE);
        source.poke(COIN_3, id); // the launchpad pays the escrow, as distribute's first step does
        uint256 owed = e.claimable(address(l));
        assertGt(owed, 0);

        vm.expectEmit(address(l));
        emit ClaimFailed();
        l.distribute{gas: 450_000}();
        assertEq(e.claimable(address(l)), owed, "the credit waits");

        uint256 routed = l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve();
        l.distribute{gas: 2_000_000}();
        assertEq(e.claimable(address(l)), 0);
        assertEq(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve() - routed, owed);
    }

    event ClaimFailed();

    function _buybackRuns(address coin) internal {
        Lodestar l = _activate(coin, address(v5swapper));
        _trade(coin, 20 ether, 10);
        uint256 sinkBefore = IERC20(coin).balanceOf(BURN_SINK);
        l.distribute();
        // Ascend's EMA only moves on swaps, and after the big buys above it trails spot; a few small trades over
        // the next two hours let it catch up, as normal trading would. Until then the floor skips the buyback.
        for (uint256 i; i < 20; ++i) {
            skip(6 minutes);
            _buy(coin, 0.1 ether, locker);
        }
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0, "bought back through the real pool");
        assertEq(IERC20(coin).balanceOf(BURN_SINK) - sinkBefore, l.totalBuybackTokensBurned());
    }

    function test_buybackCoinIsCurrency1() public {
        _buybackRuns(COIN_1);
    }

    function test_buybackCoinIsCurrency0() public {
        _buybackRuns(COIN_3);
    }

    /// @dev A 10% pool is under the 11% cap, so its buyback runs, net of the fee.
    function test_buybackOnATenPercentCoin() public {
        _buybackRuns(COIN_10);
    }

    function test_handBackOut() public {
        Lodestar l = _activate(COIN_3, address(0));
        address next = makeAddr("next");
        vm.prank(l.steward());
        l.transferCreatorOut(next);
        IAscendV5Escrow e = _escrow(COIN_3);
        assertEq(e.pendingRecipient(), next);
        vm.prank(l.steward());
        l.transferCreatorOut(address(0));
        assertEq(e.pendingRecipient(), address(0), "proposing no one cancels");
    }

    function test_swapperRefusesOtherPools() public {
        vm.expectRevert(AscendV5Swapper.UnknownPool.selector);
        v5swapper.keyOf(bytes32(uint256(1)));
    }

    /// @dev on a pool that opted in to Ascend's community takeovers (most v5 launches), Ascend's CTO
    /// registry can move the escrow's recipient away from the router, creator lock or not.
    function test_communityTakeoverOverridesTheLock() public {
        IAscendV5Escrow e = _escrow(COIN_10);
        ICtoRegistryV5 reg = ICtoRegistryV5(e.ctoRegistry());
        assertTrue(address(reg) != address(0), "COIN_10 opted in to takeovers");
        (bytes32 pid,,) = source.resolve(COIN_10, WHYPE);
        assertEq(source.takeoverRegistry(pid), address(reg));
        address dev = e.recipient();
        (address predicted,) = factory.predict(COIN_10, WHYPE);
        vm.prank(dev);
        e.proposeRecipient(predicted);
        LodestarFactory.DeployParams memory p = _v5params(COIN_10, address(0));
        p.creatorLockUntil = type(uint64).max;
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory.deploy(p)));
        skip(2 days);
        l.acceptCreator();
        assertTrue(l.creatorRoleLocked());
        _trade(COIN_10, 20 ether, 5);
        uint256 credit = e.claimable(address(l));
        assertGt(credit, 0);

        address applicant = makeAddr("applicant");
        (bytes32 id,,) = source.resolve(COIN_10, WHYPE);
        vm.prank(applicant);
        uint256 req = reg.submitRequest(id, "https://x.com/someone/status/1234567890");
        vm.prank(reg.owner());
        reg.review(req, true, "https://x.com/ascend/status/1");
        skip(reg.NOTICE() + 1);
        vm.prank(applicant);
        reg.accept(req);
        assertEq(e.recipient(), applicant, "the takeover moved the role despite the forever lock");
        assertFalse(l.creatorRoleLocked());
        assertGe(e.claimable(address(l)), credit, "credits the router earned stay claimable");
        l.distribute();
        assertEq(e.claimable(address(l)), 0, "and the router still routes them");
        assertEq(l.creatorLockedUntil(), type(uint64).max);
    }

    /// @dev a lock set at deploy binds nothing until the router accepts; the creator can still cancel.
    function test_lockBindsOnlyOnceAccepted() public {
        IAscendV5Escrow e = _escrow(COIN_3);
        address dev = e.recipient();
        (address predicted,) = factory.predict(COIN_3, WHYPE);
        vm.prank(dev);
        e.proposeRecipient(predicted);
        LodestarFactory.DeployParams memory p = _v5params(COIN_3, address(0));
        p.creatorLockUntil = type(uint64).max;
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory.deploy(p)));
        assertEq(l.creatorLockedUntil(), type(uint64).max);
        assertFalse(l.creatorRoleLocked(), "not binding while the creator can still cancel");
        vm.prank(dev);
        e.proposeRecipient(address(0));
        skip(2 days);
        vm.expectRevert(Lodestar.CreatorNotPending.selector);
        l.acceptCreator();
        assertFalse(l.isCreator());
        assertEq(e.recipient(), dev, "the creator kept the role");
    }

    /// @dev fees held before the hand-off (below Ascend's graduation line) are paid to whoever is the
    /// recipient when the coin graduates.
    function test_heldFeesGoToTheRecipientAtGraduation() public {
        IAscendV5Escrow e = _escrow(COIN_3);
        address dev = e.recipient();
        _trade(COIN_3, 20 ether, 5);
        uint256 heldBefore = e.held();
        uint256 devBefore = e.claimable(dev);
        assertGt(heldBefore, 0, "fees held before the hand-off");
        Lodestar l = _activate(COIN_3, address(0));
        uint256 routerBefore = e.claimable(address(l));
        // push the coin over the line and keep it there
        for (uint256 i; i < 12; ++i) {
            _buy(COIN_3, 300 ether, locker);
            skip(10 minutes);
            try IEscrowLifecycle(address(e)).startHold() {} catch {}
            try IEscrowLifecycle(address(e)).graduate() {} catch {}
        }
        assertEq(e.phase(), 1, "graduated");
        assertEq(e.held(), 0);
        assertEq(e.claimable(dev), devBefore, "the old recipient gets none of the held fees");
        assertGt(
            e.claimable(address(l)) - routerBefore, heldBefore, "the router gets them, with what it earned"
        );
    }

    /// @dev once the router holds the role, the old recipient has no escrow call left that moves the role
    /// or the router's credits.
    function test_oldRecipientHasNoPowerLeft() public {
        IAscendV5Escrow e = _escrow(COIN_1);
        address dev = e.recipient();
        Lodestar l = _activate(COIN_1, address(0));
        _trade(COIN_1, 20 ether, 5);
        uint256 credit = e.claimable(address(l));
        bytes[7] memory calls = [
            abi.encodeWithSignature("proposeRecipient(address)", dev),
            abi.encodeWithSignature("reassign(address)", dev),
            abi.encodeWithSignature("proposeBuilder(address)", dev),
            abi.encodeWithSignature("setListing(address,uint256)", dev, 1 ether),
            abi.encodeWithSignature("takeListing(address,uint256)", dev, 1),
            abi.encodeWithSignature("withdrawTo(address)", dev),
            abi.encodeWithSignature("acceptBuilder()")
        ];
        // only withdrawTo goes through, and it pays the old recipient's own credit
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(dev);
            (bool ok,) = address(e).call(calls[i]);
            assertEq(ok, i == 5);
        }
        assertEq(e.recipient(), address(l));
        assertEq(e.pendingRecipient(), address(0));
        assertEq(e.claimable(address(l)), credit);
    }

    /// @dev a proposal does not expire, and proposing again restarts the 48 hours.
    function test_proposalDoesNotExpireAndCanRestart() public {
        IAscendV5Escrow e = _escrow(COIN_3);
        address dev = e.recipient();
        (address predicted,) = factory.predict(COIN_3, WHYPE);
        vm.prank(dev);
        e.proposeRecipient(predicted);
        uint256 first = e.recipientReadyAt();
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory.deploy(_v5params(COIN_3, address(0)))));
        skip(1 days);
        vm.prank(dev);
        e.proposeRecipient(predicted);
        assertEq(e.recipientReadyAt(), first + 1 days, "proposing again restarts the wait");
        skip(30 days);
        l.acceptCreator();
        assertTrue(l.isCreator(), "still acceptable a month later");
    }
}
