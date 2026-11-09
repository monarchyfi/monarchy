// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MonarchyFixture} from "./utils/MonarchyFixture.sol";
import {Lodestar} from "../src/Lodestar.sol";
import {LodestarFactory} from "../src/LodestarFactory.sol";
import {ILodestar} from "../src/interfaces/ILodestar.sol";
import {Sandfall} from "../src/Sandfall.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockSwapper} from "../src/mocks/MockSwapper.sol";
import {IExile} from "../src/interfaces/IExile.sol";
import {Exile} from "../src/Exile.sol";
import {IAscendLaunchpad} from "../src/interfaces/IAscendLaunchpad.sol";
import {IListingDesk} from "../src/interfaces/IListingDesk.sol";
import {ICLPoolManager} from "../src/interfaces/IInfinity.sol";
import {ISandfall} from "../src/interfaces/ISandfall.sol";
import {MonarchTiers} from "../src/libraries/MonarchTiers.sol";
import {IFeeSource} from "../src/interfaces/IFeeSource.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev A stand-in for a newer Monarchy factory: a router only asks it where this token's router lives.
contract MockSuccessorFactory {
    address public router;

    constructor(address router_) {
        router = router_;
    }

    function predict(address, address) external view returns (address, bytes32) {
        return (router, bytes32(0));
    }
}

contract LodestarTest is MonarchyFixture {
    MockERC20 internal token;
    bytes32 internal poolId;
    MockSwapper internal mockSwapper;

    // pool price: 800M tokens per 50k USDC = 1.6e16 token wei per USDC wei
    uint256 internal constant TOKENS_PER_QUOTE = 16_000e18 * 1e12;

    function setUp() public {
        _deployCore(address(0));
        (token, poolId) = _launch("MONARCH");
        mockSwapper = new MockSwapper(usdc, token, TOKENS_PER_QUOTE);
    }

    function _activateDefault(bool listing) internal returns (Lodestar) {
        return _activate(_params(token, 4_000, 4_000, 2_000, address(mockSwapper), listing));
    }

    // ---------------------------------------------------------------- 1. factory

    function test_predictMatchesDeployedClone() public {
        (address predicted, bytes32 id) = factory.predict(address(token), address(usdc));
        assertEq(id, poolId);
        Lodestar l = _activateDefault(false);
        assertEq(address(l), predicted);
        assertEq(launchpad.poolCreator(poolId), address(l));
        assertEq(launchpad.pendingCreator(poolId), address(0));
        assertTrue(l.isCreator());
        assertEq(l.steward(), dev);
        assertEq(factory.lodestarOf(address(token)), address(l));
        assertEq(factory.allLodestarsLength(), 1);
        // satellites are wired to the router
        Sandfall.Stream memory s = sandfall.stream(l.treasuryStreamId());
        assertEq(s.creator, address(l));
        assertEq(s.recipient, treasury);
        assertFalse(s.cancellable);
        assertEq(exile.poolInfo(l.exilePoolId()).admin, address(l), "the router administers the reward pool");
    }

    function test_deployRequiresTransferFirst() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.TransferCreatorFirst.selector);
        factory.deploy(p);
    }

    function test_deployOnlyByPoolCreator() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        (address predicted,) = factory.predict(address(token), address(usdc));
        vm.prank(dev);
        launchpad.transferCreator(poolId, predicted);
        vm.prank(trader);
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(p);
    }

    function test_deployRejectsSwappedTokenAndQuote() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        (p.token, p.quote) = (p.quote, p.token);
        (address predicted,) = factory.predict(p.token, p.quote);
        vm.prank(dev);
        launchpad.transferCreator(poolId, predicted);
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.WrongTokenOrder.selector);
        factory.deploy(p);
    }

    /// @dev The owner role moves in two steps, so handing it to a multisig can't strand it on a mistyped address.
    function test_ownerHandoverTakesTwoSteps() public {
        assertEq(factory.owner(), address(this));
        address multisig = makeAddr("multisig");
        vm.prank(trader);
        vm.expectRevert(LodestarFactory.OnlyOwner.selector);
        factory.transferOwner(trader);

        factory.transferOwner(multisig);
        assertEq(factory.owner(), address(this), "nothing moves until it is accepted");
        assertEq(factory.pendingOwner(), multisig);
        vm.prank(trader);
        vm.expectRevert(LodestarFactory.NotPendingOwner.selector);
        factory.acceptOwner();
        vm.prank(multisig);
        factory.acceptOwner();
        assertEq(factory.owner(), multisig);
        assertEq(factory.pendingOwner(), address(0));
        vm.expectRevert(LodestarFactory.OnlyOwner.selector);
        factory.setSuccessor(trader);

        // a pending handover can be cancelled
        vm.startPrank(multisig);
        factory.transferOwner(trader);
        factory.transferOwner(address(0));
        vm.stopPrank();
        vm.prank(trader);
        vm.expectRevert(LodestarFactory.NotPendingOwner.selector);
        factory.acceptOwner();
    }

    function test_factoryNeedsAnOwner() public {
        vm.expectRevert(LodestarFactory.ZeroAddress.selector);
        new LodestarFactory(
            address(impl),
            IFeeSource(address(ascendSource)),
            exile,
            ISandfall(address(sandfall)),
            address(swapper),
            address(0)
        );
    }

    function test_newDefaultSwapperWaitsTwelveHours() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(0), false);
        (address predicted,) = factory.predict(p.token, p.quote);
        vm.prank(dev);
        launchpad.transferCreator(poolId, predicted);
        factory.setDefaultSwapper(makeAddr("skimmer")); // the owner tries to slip in a new default
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.DefaultSwapperJustChanged.selector);
        factory.deploy(p);
        // naming a swapper explicitly still works
        p.cfg.swapper = address(mockSwapper);
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory.deploy{gas: 5_000_000}(p)));
        assertEq(l.config().swapper, address(mockSwapper));
    }

    function test_cannotDeployTwice() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        _activate(p);
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(p);
    }

    function test_implementationAndCloneCannotBeReinitialized() public {
        Lodestar l = _activateDefault(false);
        ILodestar.InitParams memory ip;
        vm.expectRevert(Lodestar.AlreadyInitialized.selector);
        impl.initialize(ip);
        vm.expectRevert(Lodestar.AlreadyInitialized.selector);
        l.initialize(ip);
    }

    function test_defaultSwapperFillsIn() public {
        Lodestar l = _activate(_params(token, 4_000, 4_000, 2_000, address(0), false));
        assertEq(l.config().swapper, address(swapper));
    }

    function test_invalidSplitRejected() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 1_000, address(mockSwapper), false);
        (address predicted,) = factory.predict(address(token), address(usdc));
        vm.prank(dev);
        launchpad.transferCreator(poolId, predicted);
        vm.prank(dev);
        vm.expectRevert(Lodestar.InvalidConfig.selector);
        factory.deploy(p);
    }

    // ---------------------------------------------------------------- 2. listing

    function test_listingElectionMovesToRouter() public {
        vm.prank(dev);
        desk.enroll(address(token), address(usdc), 1_000e6);
        assertEq(address(uint160(launchpad.listingElection(poolId))), dev);

        Lodestar l = _activateDefault(true);
        uint256 e = launchpad.listingElection(poolId);
        assertEq(address(uint160(e)), address(l), "election now belongs to the router");
        assertEq(e >> 168, 5_000e6, "router's cap");
    }

    function test_noListingWhenDisabled() public {
        _activateDefault(false);
        assertEq(launchpad.listingElection(poolId), 0);
    }

    // ---------------------------------------------------------------- 3. distribute

    function test_distributeWithListing() public {
        Lodestar l = _activateDefault(true);
        launchpad.injectFees(poolId, 1000e18, 1000e6);
        uint256 deadBefore = token.balanceOf(DEAD);

        l.distribute();

        // creator gets 500 of each; 20% of the quote share (100) goes to the listing set-aside
        assertEq(launchpad.listingOwed(poolId), 100e6);
        assertEq(l.totalTokenBurned(), 500e18);
        assertEq(l.totalBuybackQuote(), 160e6);
        assertEq(l.totalHoldersQuote(), 160e6);
        assertEq(l.totalTreasuryQuote(), 80e6);
        assertEq(l.totalBuybackTokensBurned(), 160e6 * TOKENS_PER_QUOTE / 1e18);
        assertEq(token.balanceOf(DEAD) - deadBefore, 500e18 + l.totalBuybackTokensBurned());
        assertEq(usdc.balanceOf(address(exile)), 160e6);
        assertEq(usdc.balanceOf(address(sandfall)), 80e6);
        assertEq(token.balanceOf(address(l)), 0);
        assertEq(usdc.balanceOf(address(l)), 0);
        assertEq(l.buybackReserve(), 0);
    }

    /// @dev Ascend tokens reject the usual 0x…dEaD address (found on Elysium testnet), so Lodestar burns
    /// to a different dead address. Both the direct burn and the buyback must land there.
    function test_burnsDespiteTokenRejectingZeroXDead() public {
        Lodestar l = _activate(_params(token, 4_000, 4_000, 2_000, address(0), false));
        address classicDead = 0x000000000000000000000000000000000000dEaD;
        _buy(poolId, trader, 1_000e6);
        vm.prank(trader);
        vm.expectRevert();
        token.transfer(classicDead, 1);

        launchpad.injectFees(poolId, 1000e18, 1000e6);
        l.distribute();
        assertGe(l.totalTokenBurned(), 500e18, "token fees burned");
        assertGt(l.totalBuybackTokensBurned(), 0, "buyback went through the real swapper");
        assertEq(l.buybackReserve(), 0);
        assertEq(token.balanceOf(address(l)), 0);
    }

    function test_distributeWithoutListing() public {
        Lodestar l = _activateDefault(false);
        launchpad.injectFees(poolId, 1000e18, 1000e6);
        l.distribute();
        assertEq(l.totalBuybackQuote(), 200e6);
        assertEq(l.totalHoldersQuote(), 200e6);
        assertEq(l.totalTreasuryQuote(), 100e6);
        assertEq(usdc.balanceOf(address(l)), 0);
    }

    function test_previewMatchesClaimable() public {
        Lodestar l = _activateDefault(false);
        launchpad.injectFees(poolId, 1000e18, 1000e6);
        launchpad.collect(poolId);
        (uint256 t, uint256 q, uint256 b, uint256 h, uint256 tr) = l.previewDistribute();
        assertEq(t, 500e18);
        assertEq(q, 500e6);
        assertEq(b + h + tr, q);
        assertEq(tr, 100e6);
    }

    // ---------------------------------------------------------------- 4. unannounced funds

    function test_routesFundsClaimedOrSentByOthers() public {
        Lodestar l = _activateDefault(false);
        launchpad.injectFees(poolId, 0, 1000e6);
        // Ascend's keeper collects and claims on its own schedule: funds land in the router
        vm.startPrank(trader);
        launchpad.collect(poolId);
        launchpad.claim(poolId);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(l)), 500e6);
        // and someone donates
        usdc.mint(address(l), 100e6);

        l.distribute();
        assertEq(l.totalBuybackQuote() + l.totalHoldersQuote() + l.totalTreasuryQuote(), 600e6);
        assertEq(usdc.balanceOf(address(l)), 0);
    }

    // ---------------------------------------------------------------- 5. remainder

    function testFuzz_splitConservesQuote(uint16 burn, uint16 holders, uint96 quoteFees) public {
        burn = uint16(bound(burn, 0, 10_000));
        holders = uint16(bound(holders, 0, 10_000 - burn));
        uint16 treas = 10_000 - burn - holders;
        quoteFees = uint96(bound(quoteFees, 0, 1e15));

        Lodestar l = _activate(_params(token, burn, holders, treas, address(mockSwapper), false));
        launchpad.injectFees(poolId, 0, quoteFees);
        l.distribute();

        uint256 q = uint256(quoteFees) * 5_000 / 10_000;
        uint256 burnQ = q * burn / 10_000;
        uint256 holdQ = q * holders / 10_000;
        uint256 rest = q - burnQ - holdQ;
        if (treas == 0) {
            if (holders > 0) holdQ += rest;
            else burnQ += rest;
        }
        // big buybacks are capped per call; the rest waits in reserve
        assertEq(l.totalBuybackQuote() + l.buybackReserve(), burnQ, "buyback share");
        assertEq(l.totalHoldersQuote(), holdQ, "holder share");
        assertEq(l.totalBuybackQuote() + l.buybackReserve() + l.totalHoldersQuote() + l.totalTreasuryQuote(), q);
        assertEq(usdc.balanceOf(address(l)), l.buybackReserve());
    }

    // ---------------------------------------------------------------- 6. buyback skip

    function test_failedBuybackWaitsInReserve() public {
        Lodestar l = _activateDefault(false);
        mockSwapper.setFail(true);
        launchpad.injectFees(poolId, 0, 1000e6);

        vm.expectEmit(false, false, false, false, address(l));
        emit Lodestar.BuybackSkipped(0, 0);
        l.distribute();
        assertEq(l.buybackReserve(), 200e6);
        assertEq(usdc.balanceOf(address(l)), 200e6);
        assertEq(l.totalHoldersQuote(), 200e6, "holders still paid");
        assertEq(l.totalTreasuryQuote(), 100e6, "treasury still paid");

        mockSwapper.setFail(false);
        launchpad.injectFees(poolId, 0, 1000e6);
        uint256 cap = l.maxBuyback(); // 0.5% of the pool's 50k USDC side
        assertApproxEqRel(cap, 250e6, 1e15);
        l.distribute();
        // after a skip the next attempt is half of the capped size
        assertEq(l.totalBuybackQuote(), cap / 2, "half size after a skip");
        assertEq(l.totalHoldersQuote(), 400e6, "reserve is not split again");

        for (uint256 i; i < 5 && l.buybackReserve() > 0; ++i) {
            vm.warp(block.timestamp + 30 minutes); // buybacks are at least 30 minutes apart
            l.distribute();
        }
        assertEq(l.totalBuybackQuote(), 400e6, "everything bought back in pieces");
        assertEq(l.buybackReserve(), 0);
        assertEq(usdc.balanceOf(address(l)), 0);
        assertEq(l.buybackShift(), 0);
    }

    function test_reserveTooBigForPoolIsBoughtInPieces() public {
        Lodestar l = _activateDefault(false);
        // a month without a swapper builds a reserve far bigger than the pool can take in one buy
        mockSwapper.setFail(true);
        for (uint256 i; i < 30; ++i) {
            launchpad.injectFees(poolId, 0, 1000e6);
            l.distribute();
        }
        assertEq(l.buybackReserve(), 6_000e6);
        mockSwapper.setFail(false);
        mockSwapper.setMaxIn(500e6);

        for (uint256 i; i < 40 && l.buybackReserve() > 0; ++i) {
            vm.warp(block.timestamp + 1 hours);
            l.distribute();
        }
        assertEq(l.buybackReserve(), 0, "reserve unstuck");
        assertEq(l.totalBuybackQuote(), 6_000e6);
        assertEq(usdc.balanceOf(address(mockSwapper)), 6_000e6);
    }

    function test_eachBuybackIsCappedByPoolDepth() public {
        Lodestar l = _activate(_params(token, 10_000, 0, 0, address(mockSwapper), false));
        launchpad.injectFees(poolId, 0, 4_000e6); // 2,000 USDC to buy back
        uint256 cap = l.maxBuyback();
        assertEq(l.nextBuybackAt(), 0, "nothing bought yet: no wait");
        l.distribute();
        assertEq(l.totalBuybackQuote(), cap, "one capped piece per distribute");
        assertEq(l.buybackReserve(), 2_000e6 - cap);
    }

    function test_dustDoesNotShrinkTheNextBuyback() public {
        Lodestar l = _activateDefault(false);
        mockSwapper.setMaxIn(1e6); // dust-sized attempts fail, like a pool rounding its fee up
        for (uint256 i; i < 10; ++i) {
            usdc.mint(address(l), 3);
            l.distribute();
        }
        assertEq(l.buybackShift(), 0, "dust failures don't count");
    }

    function test_emaFailureDoesNotBlockDistribute() public {
        Lodestar l = _activateDefault(false);
        launchpad.injectFees(poolId, 0, 1000e6);
        vm.mockCallRevert(address(launchpad), abi.encodeWithSignature("emaSqrtPrice(bytes32)", poolId), "down");
        l.distribute();
        assertEq(l.buybackReserve(), 200e6, "buyback waits");
        assertEq(l.totalHoldersQuote(), 200e6, "holders still paid");
        assertEq(l.totalTreasuryQuote(), 100e6, "treasury still paid");
    }

    function test_failedHolderPayoutIsKeptForThem() public {
        Lodestar l = _activateDefault(false);
        launchpad.injectFees(poolId, 0, 1000e6);
        vm.mockCallRevert(address(exile), abi.encodeWithSignature("notifyReward(uint256,uint256)"), "stuck");
        l.distribute();
        assertEq(l.holdersReserve(), 200e6);
        assertEq(l.totalTreasuryQuote(), 100e6, "treasury still paid");
        vm.clearMockedCalls();
        l.distribute();
        assertEq(l.holdersReserve(), 0);
        assertEq(l.totalHoldersQuote(), 200e6, "holders get all of it, not a re-split");
        assertEq(l.totalTreasuryQuote(), 100e6);
    }

    function test_noTreasuryShareSendsRemainderToHolders() public {
        Lodestar l = _activate(_params(token, 5_000, 5_000, 0, address(mockSwapper), false));
        launchpad.injectFees(poolId, 0, 3); // 1 quote unit to split, all rounding
        usdc.mint(address(l), 2);
        l.distribute();
        assertEq(l.totalTreasuryQuote(), 0, "treasury stream untouched");
    }

    function test_swapperThatBurnsNothingIsRejected() public {
        Lodestar l = _activateDefault(false);
        mockSwapper.setShortChange(true);
        launchpad.injectFees(poolId, 0, 1000e6);
        l.distribute();
        assertEq(l.totalBuybackQuote(), 0, "no credit for a buy that burned nothing");
        assertEq(l.buybackReserve(), 200e6, "quote kept in reserve");
        assertEq(usdc.balanceOf(address(l)), 200e6);
        assertEq(usdc.balanceOf(address(mockSwapper)), 0);
    }

    function test_buybackStepOnlyFromItself() public {
        Lodestar l = _activateDefault(false);
        vm.expectRevert(Lodestar.OnlySelf.selector);
        l.buybackStep(address(mockSwapper), 1e6, 1);
    }

    function test_claimFailureDoesNotBlock() public {
        Lodestar l = _activateDefault(false);
        usdc.mint(address(l), 1000e6); // e.g. a listing refund
        vm.mockCallRevert(address(launchpad), abi.encodeWithSignature("claim(bytes32)", poolId), "paused");
        l.distribute();
        assertEq(l.totalHoldersQuote(), 400e6, "balance still routed");
    }

    function test_noSwapperKeepsReserve() public {
        Lodestar l = _activateDefault(false);
        vm.prank(dev);
        l.proposeConfig(ILodestar.Config(4_000, 4_000, 2_000, address(0), 300, false));
        vm.warp(block.timestamp + 12 hours);
        l.executeConfig();
        // factory default only applies at deploy; a later config may set no swapper
        assertEq(l.config().swapper, address(0));
        launchpad.injectFees(poolId, 0, 1000e6);
        l.distribute();
        assertEq(l.buybackReserve(), 200e6);
    }

    // ---------------------------------------------------------------- 8. timelock

    function test_configTimelock() public {
        Lodestar l = _activateDefault(false);
        ILodestar.Config memory c = ILodestar.Config(2_000, 6_000, 2_000, address(mockSwapper), 500, false);

        vm.prank(trader);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.proposeConfig(c);

        vm.expectRevert(Lodestar.NoPendingConfig.selector);
        l.executeConfig();

        vm.prank(dev);
        l.proposeConfig(c);
        (, uint64 eta) = l.pendingConfig();
        assertEq(eta, block.timestamp + 12 hours);

        vm.warp(eta - 1);
        vm.expectRevert(Lodestar.TimelockActive.selector);
        l.executeConfig();

        // re-proposing resets the clock
        vm.prank(dev);
        l.proposeConfig(c);
        vm.warp(eta);
        vm.expectRevert(Lodestar.TimelockActive.selector);
        l.executeConfig();

        vm.warp(block.timestamp + 12 hours);
        vm.prank(trader); // anyone can execute once the timelock passes
        l.executeConfig();
        assertEq(l.config().holdersBps, 6_000);
        assertEq(l.config().maxSlippageBps, 500);
    }

    function test_readyConfigExpires() public {
        Lodestar l = _activateDefault(false);
        vm.prank(dev);
        l.proposeConfig(ILodestar.Config(2_000, 6_000, 2_000, address(mockSwapper), 500, false));
        (, uint64 eta) = l.pendingConfig();
        vm.warp(eta + 7 days + 1);
        vm.expectRevert(Lodestar.ProposalExpired.selector);
        l.executeConfig();
        assertEq(l.config().holdersBps, 4_000);
    }

    function test_cancelConfig() public {
        Lodestar l = _activateDefault(false);
        vm.prank(dev);
        l.proposeConfig(ILodestar.Config(0, 10_000, 0, address(mockSwapper), 300, false));
        vm.prank(dev);
        l.cancelConfig();
        vm.warp(block.timestamp + 73 hours);
        vm.expectRevert(Lodestar.NoPendingConfig.selector);
        l.executeConfig();
        assertEq(l.config().holdersBps, 4_000);
    }

    function test_configValidation() public {
        Lodestar l = _activateDefault(false);
        vm.startPrank(dev);
        vm.expectRevert(Lodestar.InvalidConfig.selector);
        l.proposeConfig(ILodestar.Config(5_000, 5_000, 1, address(mockSwapper), 300, false));
        vm.expectRevert(Lodestar.InvalidConfig.selector);
        l.proposeConfig(ILodestar.Config(5_000, 5_000, 0, address(mockSwapper), 2_001, false));
        vm.expectRevert(Lodestar.InvalidConfig.selector);
        l.proposeConfig(ILodestar.Config(5_000, 5_000, 0, address(mockSwapper), 99, false)); // would block every buyback
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- 9. creator lock

    function test_creatorLock() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        p.creatorLockUntil = uint64(block.timestamp + 365 days);
        Lodestar l = _activate(p);
        assertEq(l.creatorLockedUntil(), p.creatorLockUntil);

        vm.startPrank(dev);
        vm.expectRevert(Lodestar.CreatorRoleIsLocked.selector);
        l.transferCreatorOut(dev);
        vm.expectRevert(Lodestar.NotExtending.selector);
        l.lockCreatorRole(uint64(block.timestamp + 30 days));
        vm.stopPrank();

        vm.warp(p.creatorLockUntil);
        vm.prank(dev);
        l.transferCreatorOut(dev);
        assertEq(launchpad.pendingCreator(poolId), dev);
    }

    function test_cannotLockWhileAHandOffIsPending() public {
        Lodestar l = _activateDefault(false);
        address alt = makeAddr("alt");
        vm.startPrank(dev);
        l.transferCreatorOut(alt);
        vm.expectRevert(Lodestar.CreatorTransferPending.selector);
        l.lockCreatorRole(type(uint64).max);
        // cancelling the hand-off, then locking, works
        l.transferCreatorOut(address(0));
        l.lockCreatorRole(type(uint64).max);
        vm.stopPrank();
        vm.prank(alt);
        vm.expectRevert();
        launchpad.acceptCreator(poolId);
        assertTrue(l.isCreator());
    }

    function test_cancelAllowedWhileLocked() public {
        Lodestar l = _activateDefault(false);
        vm.prank(dev);
        l.lockCreatorRole(type(uint64).max);
        vm.prank(dev);
        l.transferCreatorOut(address(0)); // cancelling never hands the role anywhere
        assertEq(launchpad.pendingCreator(poolId), address(0));
    }

    function test_creatorLockForever() public {
        Lodestar l = _activateDefault(false);
        vm.prank(dev);
        l.lockCreatorRole(type(uint64).max);
        vm.warp(block.timestamp + 100 * 365 days);
        vm.prank(dev);
        vm.expectRevert(Lodestar.CreatorRoleIsLocked.selector);
        l.transferCreatorOut(dev);
    }

    function test_onlyStewardControlsRole() public {
        Lodestar l = _activateDefault(false);
        vm.startPrank(trader);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.transferCreatorOut(trader);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.lockCreatorRole(type(uint64).max);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.transferSteward(trader);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.proposeTiers(MonarchTiers.defaults());
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.cancelTiers();
        // accepting the role is open to anyone, but only completes a hand-off Ascend already holds
        vm.expectRevert(Lodestar.CreatorNotPending.selector);
        l.acceptCreator();
        vm.stopPrank();

        vm.prank(dev);
        l.transferSteward(trader);
        vm.prank(trader);
        l.acceptSteward();
        assertEq(l.steward(), trader);
    }

    /// @dev The steward role moves in two steps, like the factory's and Exile's owner roles: a mistyped address
    /// can neither strand it nor hand a stranger the config, and nothing changes until the new steward accepts.
    function test_stewardHandoverIsTwoStep() public {
        Lodestar l = _activateDefault(false);
        address stranger = makeAddr("stranger");

        vm.prank(dev);
        l.transferSteward(trader);
        assertEq(l.steward(), dev, "the role stays put until accepted");
        assertEq(l.pendingSteward(), trader);
        // the named address has no powers yet, and nobody else can take the handover
        vm.prank(trader);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.lockCreatorRole(type(uint64).max);
        vm.prank(stranger);
        vm.expectRevert(Lodestar.NotPendingSteward.selector);
        l.acceptSteward();
        // the current steward still acts, and naming 0 cancels
        vm.prank(dev);
        l.transferSteward(address(0));
        assertEq(l.pendingSteward(), address(0));
        vm.prank(trader);
        vm.expectRevert(Lodestar.NotPendingSteward.selector);
        l.acceptSteward();

        vm.prank(dev);
        l.transferSteward(trader);
        vm.prank(trader);
        l.acceptSteward();
        assertEq(l.steward(), trader);
        assertEq(l.pendingSteward(), address(0));
        vm.prank(dev);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.transferSteward(dev);
        // a pending handover can't be accepted twice
        vm.prank(trader);
        vm.expectRevert(Lodestar.NotPendingSteward.selector);
        l.acceptSteward();
    }

    // ---------------------------------------------------------------- 10. reentrancy

    function test_reentrantSwapperFallsBackToReserve() public {
        Lodestar l = _activateDefault(false);
        mockSwapper.setReenter(address(l), abi.encodeCall(Lodestar.distribute, ()));
        launchpad.injectFees(poolId, 0, 1000e6);
        l.distribute();
        assertEq(l.buybackReserve(), 200e6, "re-entry reverted inside the try, buyback waits");
        assertEq(l.totalHoldersQuote(), 200e6);
    }

    // ---------------------------------------------------------------- 11. collect failure

    function test_collectFailureDoesNotBlock() public {
        Lodestar l = _activateDefault(false);
        launchpad.injectFees(poolId, 0, 1000e6);
        launchpad.collect(poolId);
        launchpad.setCollectReverts(poolId, true);

        vm.expectEmit(false, false, false, false, address(l));
        emit Lodestar.CollectFailed();
        l.distribute();
        assertEq(l.totalHoldersQuote(), 200e6, "already-owed fees still claimed and routed");
    }

    // ---------------------------------------------------------------- 12. gas

    function test_gasDistributeWithRealSwapper() public {
        Lodestar l = _activate(_params(token, 4_000, 4_000, 2_000, address(0), true));
        _buy(poolId, trader, 10_000e6);
        uint256 g = gasleft();
        l.distribute(); // first run pays for fresh storage slots everywhere
        uint256 first = g - gasleft();

        vm.warp(block.timestamp + 1 hours);
        _buy(poolId, trader, 10_000e6);
        g = gasleft();
        l.distribute();
        uint256 steady = g - gasleft();

        emit log_named_uint("distribute gas (first)", first);
        emit log_named_uint("distribute gas (steady)", steady);
        // Loose ceilings: measured gas differs between forge versions (about 440k steady locally,
        // 670k on CI's stable forge), and Elysium gas is cheap. This guards against blow-ups only.
        assertLt(first, 1_200_000);
        assertLt(steady, 1_000_000);
        assertGt(l.totalBuybackTokensBurned(), 0);
    }

    // ---------------------------------------------------------------- 13. second review: buyback timing and prices

    /// @dev The depth cap bounds one buy. Buys are also at least 30 minutes apart, so calling distribute
    /// many times in one block moves one capped piece, not the whole reserve.
    function test_buybacksAreAtLeastThirtyMinutesApart() public {
        Lodestar l = _activate(_params(token, 10_000, 0, 0, address(mockSwapper), false));
        launchpad.injectFees(poolId, 0, 4_000e6); // 2,000 USDC to buy back
        uint256 cap = l.maxBuyback();
        assertEq(l.nextBuybackAt(), 0, "nothing bought yet: no wait");
        l.distribute();
        assertEq(l.totalBuybackQuote(), cap);
        assertEq(l.nextBuybackAt(), block.timestamp + 30 minutes);
        assertEq(l.buybackShift(), 0);

        l.distribute();
        l.distribute();
        assertEq(l.totalBuybackQuote(), cap, "one buyback per 30 minutes, however often distribute is called");
        assertEq(l.buybackReserve(), 2_000e6 - cap);
        assertEq(l.buybackShift(), 0, "waiting is not a skip");

        vm.warp(block.timestamp + 30 minutes - 1);
        l.distribute();
        assertEq(l.totalBuybackQuote(), cap, "still inside the 30 minutes");
        vm.warp(block.timestamp + 1);
        l.distribute();
        assertEq(l.totalBuybackQuote(), 2 * cap, "the next piece goes out 30 minutes later");
    }

    /// @dev Buy, call distribute twenty times, sell, all in one block, against the real swapper and the
    /// production 10% slippage: exactly one capped buyback happens and the round trip loses money.
    function test_sandwichAroundRepeatedDistributesGetsOneBuyback() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(swapper), false);
        p.cfg.maxSlippageBps = 1_000;
        Lodestar l = _activate(p);
        launchpad.injectFees(poolId, 0, 30_000e6); // a busy window: 6k USDC of buyback share
        l.distribute(); // keeper: first capped piece, the rest waits in buybackReserve
        assertGt(l.buybackReserve(), 20 * l.maxBuyback(), "precondition: a reserve worth many capped pieces");
        vm.warp(block.timestamp + 30 minutes); // the next piece is due

        address attacker = makeAddr("attacker");
        uint256 stake = 5_000e6;
        _buy(poolId, attacker, stake);
        uint256 buybacks;
        for (uint256 i; i < 20; ++i) {
            uint256 before = l.totalBuybackQuote();
            l.distribute();
            if (l.totalBuybackQuote() > before) ++buybacks;
        }
        _sell(poolId, token, attacker, token.balanceOf(attacker));

        assertEq(buybacks, 1, "twenty distributes in one block move one capped piece");
        assertLt(usdc.balanceOf(attacker), stake, "the sandwich loses money");
    }

    /// @dev After a dump the EMA is stale and high. The cap follows the smaller real depth and the
    /// floor follows spot, so the buyback can't be oversized or underpaid against a stale EMA.
    function test_dumpShrinksTheCapAndKeepsTheFloorAtSpot() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(swapper), false);
        p.cfg.maxSlippageBps = 1_000;
        Lodestar l = _activate(p);
        (uint160 emaBefore,,,) = pool.getSlot0(poolId);
        uint256 capBefore = l.maxBuyback();

        // a whale dumps 800M tokens; Ascend's hook recorded the pre-dump price into the EMA
        address whale = makeAddr("whale");
        token.mint(whale, 800_000_000e18);
        _sell(poolId, token, whale, 800_000_000e18);
        launchpad.setEma(poolId, emaBefore);

        (uint256 r0, uint256 r1,,) = pool.reserves(poolId);
        (uint256 tokenR, uint256 quoteR) = launchpad.poolTokenIs0(poolId) ? (r0, r1) : (r1, r0);
        uint256 cap = l.maxBuyback();
        assertLt(cap, capBefore * 6 / 10, "the cap shrank with the real depth");
        assertApproxEqRel(cap, quoteR * 50 / 10_000, 1e15, "0.5% of the depth that is really there");
        // floor: tokens at spot, less the 1% fee and the 10% slippage allowance
        uint256 minOut = l.quoteMinOut(cap, 1_000);
        assertApproxEqRel(minOut, cap * tokenR / quoteR * 89 / 100, 1e15, "the floor follows spot, not the stale EMA");

        // and a buyback at that cap moves the price by about 1%, as the cap is sized for
        launchpad.injectFees(poolId, 0, 10_000e6);
        uint256 p0 = quoteR * 1e36 / tokenR;
        l.distribute();
        (r0, r1,,) = pool.reserves(poolId);
        (tokenR, quoteR) = launchpad.poolTokenIs0(poolId) ? (r0, r1) : (r1, r0);
        uint256 p1 = quoteR * 1e36 / tokenR;
        assertGt(l.totalBuybackQuote(), 0, "the buyback went through at the spot floor");
        assertLt((p1 - p0) * 10_000 / p0, 120, "one capped buyback moves the price about 1%");
    }

    /// @dev A pump can't loosen anything: spot only ever tightens the floor and the cap stays at the
    /// EMA's depth, so a buyback at a pumped price is still refused.
    function test_pumpLeavesTheEmaInCharge() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(swapper), false);
        p.cfg.maxSlippageBps = 1_000;
        Lodestar l = _activate(p);
        (uint160 emaBefore,,,) = pool.getSlot0(poolId);
        uint256 capBefore = l.maxBuyback();
        uint256 floorBefore = l.quoteMinOut(capBefore, 1_000);

        address attacker = makeAddr("attacker");
        _buy(poolId, attacker, 10_000e6); // price up about 40%
        launchpad.setEma(poolId, emaBefore);
        assertApproxEqRel(l.maxBuyback(), capBefore, 1e12, "the cap stays at the EMA depth");
        assertEq(l.quoteMinOut(capBefore, 1_000), floorBefore, "the floor stays at the EMA floor");

        launchpad.injectFees(poolId, 0, 1_000e6);
        l.distribute();
        assertEq(l.totalBuybackQuote(), 0, "no buyback at the pumped price");
        assertEq(l.buybackReserve(), 220e6, "40% of 500, plus 40% of the pump's own 50 USDC creator fee");
    }

    /// @dev Failed attempts can't be milked for halvings: however many times distribute is called while the
    /// route keeps failing, the attempt size halves at most once every 30 minutes, the same rate at which
    /// successes double it back.
    function test_halvingIsAtMostEveryThirtyMinutes() public {
        Lodestar l = _activateDefault(false);
        launchpad.injectFees(poolId, 0, 10_000e6);
        mockSwapper.setFail(true); // a miss a smaller attempt might fix, at a calm price

        for (uint256 i; i < 8; ++i) {
            l.distribute();
        }
        assertEq(l.totalBuybackQuote(), 0);
        assertEq(l.buybackShift(), 1, "eight failed calls in one block halve once");
        assertEq(l.lastHalvingAt(), block.timestamp);

        vm.warp(block.timestamp + 30 minutes - 1);
        l.distribute();
        assertEq(l.buybackShift(), 1, "not yet");

        vm.warp(block.timestamp + 1);
        l.distribute();
        assertEq(l.buybackShift(), 2, "30 minutes later it can halve again");
    }

    /// @dev Ascend's EMA starts at the launch price and only moves on swaps, so after a pump it trails spot
    /// until people trade. While its floor asks for more than a swap at spot can pay, no attempt size gets
    /// through, so those skips don't halve: a quiet day after a launch pump leaves the next buyback full size.
    function test_emaTrailingAPumpDoesNotHalve() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(swapper), false);
        p.cfg.maxSlippageBps = 1_000;
        Lodestar l = _activate(p);
        launchpad.injectFees(poolId, 0, 10_000e6);
        (uint160 emaBefore,,,) = pool.getSlot0(poolId);
        _buy(poolId, makeAddr("pumper"), 3_500e6); // +14%, past the fee plus 10% slippage
        launchpad.setEma(poolId, emaBefore); // nobody trades after the pump, so the EMA stays behind

        for (uint256 i; i < 8; ++i) {
            l.distribute();
            vm.warp(block.timestamp + 3 hours); // keeper cadence
        }
        assertEq(l.totalBuybackQuote(), 0, "the pumped price is refused");
        assertEq(l.buybackShift(), 0, "a trailing EMA is not a reason to buy smaller");

        (uint160 spotNow,,,) = pool.getSlot0(poolId);
        launchpad.setEma(poolId, spotNow); // trades pull the EMA up to the price
        uint256 cap = l.maxBuyback();
        l.distribute();
        assertEq(l.totalBuybackQuote(), cap, "the next buyback is a full capped piece");
    }

    /// @dev With no active liquidity (a price below Ascend's first band) there is no depth to cap the buy
    /// against, so the buyback waits instead of spending the whole reserve in one swap, and the wait doesn't
    /// count as a skip. The same holds when the pool doesn't report its liquidity at all.
    function test_noActiveLiquidityWaitsInsteadOfBuyingUncapped() public {
        Lodestar l = _activate(_params(token, 10_000, 0, 0, address(mockSwapper), false));
        launchpad.injectFees(poolId, 0, 4_000e6); // 2,000 USDC to buy back
        vm.mockCall(address(pool), abi.encodeWithSelector(pool.getLiquidity.selector, poolId), abi.encode(uint128(0)));
        assertEq(l.maxBuyback(), 0, "nothing to size a buy against");
        l.distribute();
        assertEq(l.totalBuybackQuote(), 0, "waits rather than buying uncapped");
        assertEq(l.buybackReserve(), 2_000e6);
        assertEq(l.buybackShift(), 0, "and the wait doesn't count");

        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.getLiquidity.selector, poolId), "no liquidity view");
        l.distribute();
        assertEq(l.totalBuybackQuote(), 0, "an unreported liquidity fails closed too");

        vm.clearMockedCalls();
        uint256 cap = l.maxBuyback();
        assertGt(cap, 0);
        l.distribute();
        assertEq(l.totalBuybackQuote(), cap, "one capped piece once there is depth");
        assertEq(l.buybackReserve(), 2_000e6 - cap);
    }

    /// @dev The steward can't hand the role to the router itself: that would let anyone "accept" a no-op
    /// hand-off and clear the listing election.
    function test_cannotHandTheRoleToTheRouterItself() public {
        Lodestar l = _activateDefault(false);
        vm.prank(dev);
        vm.expectRevert(Lodestar.SelfTransfer.selector);
        l.transferCreatorOut(address(l));
    }

    /// @dev Skips with no EMA (a fresh pool, or the read failing) don't count as attempts, so a day of
    /// EMA-less keeper runs leaves the first priced buyback at full size.
    function test_emaLessSkipsDoNotHalve() public {
        Lodestar l = _activateDefault(false);
        vm.mockCall(
            address(launchpad), abi.encodeWithSelector(IAscendLaunchpad.emaSqrtPrice.selector, poolId), abi.encode(uint160(0))
        );
        for (uint256 i; i < 8; ++i) {
            launchpad.injectFees(poolId, 0, 100e6);
            vm.warp(block.timestamp + 3 hours);
            l.distribute();
        }
        assertEq(l.buybackShift(), 0, "nothing was attempted, so nothing halves");
        assertEq(l.buybackReserve(), 160e6);
        vm.clearMockedCalls();

        uint256 cap = l.maxBuyback();
        uint256 full = 160e6 < cap ? 160e6 : cap;
        l.distribute();
        assertEq(l.totalBuybackQuote(), full, "the first priced buyback is full size");
    }

    // ---------------------------------------------------------------- 14. second review: roles

    /// @dev The creator role can come back: once the current creator hands it to the router on Ascend,
    /// anyone can complete the hand-off, and a second deploy fails cheaply instead of burning its gas.
    function test_creatorRoleCanComeBack() public {
        Lodestar l = _activateDefault(false); // no lock
        vm.startPrank(dev);
        l.transferCreatorOut(dev);
        launchpad.acceptCreator(poolId);
        assertFalse(l.isCreator());
        launchpad.transferCreator(poolId, address(l)); // handed straight back
        vm.stopPrank();

        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.AlreadyDeployed.selector);
        factory.deploy{gas: 300_000}(p);

        vm.prank(trader);
        vm.expectEmit(address(l));
        emit Lodestar.CreatorAccepted();
        l.acceptCreator();
        assertTrue(l.isCreator(), "back with the router");

        launchpad.injectFees(poolId, 0, 1_000e6);
        l.distribute();
        assertEq(l.totalHoldersQuote(), 200e6, "fees route again");
    }

    /// @dev The router is the Exile pool's admin, so tier changes belong to whoever is steward and move
    /// with the role; the activating key alone has no say.
    function test_tierChangesFollowTheSteward() public {
        Lodestar l = _activateDefault(false);
        uint256 pid = l.exilePoolId();
        IExile.Tier[] memory t = MonarchTiers.defaults();
        t[3].multiplierBps = 40_000;

        vm.prank(dev);
        vm.expectRevert(Exile.NotAdmin.selector);
        exile.proposeTiers(pid, t);

        vm.prank(dev);
        l.proposeTiers(t);
        assertEq(exile.poolInfo(pid).tiersEta, block.timestamp + 12 hours);
        vm.prank(dev);
        l.cancelTiers();
        assertEq(exile.poolInfo(pid).tiersEta, 0);

        vm.prank(dev);
        l.transferSteward(trader);
        vm.prank(trader);
        l.acceptSteward();
        vm.prank(dev);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.proposeTiers(t);
        vm.prank(trader);
        l.proposeTiers(t);
        vm.warp(block.timestamp + 12 hours);
        exile.executeTiers(pid); // anyone, once ready
        assertEq(exile.poolInfo(pid).tiers[3].multiplierBps, 40_000);
    }

    // ---------------------------------------------------------------- 15. token-side fees to Exile lockers

    function _lockToken(Lodestar l, address who, uint256 amount, uint256 duration) internal returns (uint256 id) {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(exile), amount);
        id = exile.lockERC20(address(token), amount, uint64(block.timestamp + duration), l.exilePoolId());
        vm.stopPrank();
    }

    /// @dev With `tokenToHolders` on, every token-side fee goes to Exile lockers as a 3 day drip paid in
    /// the token, and nothing of it is burned. The quote side is untouched.
    function test_tokenSideFeesCanGoToLockers() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        p.cfg.tokenToHolders = true;
        Lodestar l = _activate(p);
        address holder = makeAddr("holder");
        uint256 id = _lockToken(l, holder, 1_000e18, 30 days);
        launchpad.injectFees(poolId, 1000e18, 1000e6);
        uint256 deadBefore = token.balanceOf(DEAD);

        vm.expectEmit(false, false, false, true, address(l));
        emit Lodestar.Distributed(0, 500e18, 500e6, 200e6, 200e6 * TOKENS_PER_QUOTE / 1e18, 200e6, 100e6);
        l.distribute();

        assertEq(l.totalTokenBurned(), 0, "nothing burned from the token side");
        assertEq(l.totalTokenToHolders(), 500e18);
        assertEq(token.balanceOf(DEAD) - deadBefore, l.totalBuybackTokensBurned(), "only the buyback burns");
        assertEq(token.balanceOf(address(l)), 0);
        assertEq(exile.poolInfo(l.exilePoolId()).stakeTotalDistributed, 500e18);
        assertEq(l.totalHoldersQuote(), 200e6, "quote side as before");

        vm.warp(block.timestamp + 3 days);
        assertApproxEqRel(exile.pendingStakeRewards(id), 500e18, 1e12, "the locker gets all of it");
        uint256 before = token.balanceOf(holder);
        vm.prank(holder);
        exile.claimRewards(id);
        assertApproxEqRel(token.balanceOf(holder) - before, 500e18, 1e12);
    }

    /// @dev The default stays a burn.
    function test_tokenSideFeesBurnByDefault() public {
        Lodestar l = _activateDefault(false);
        assertFalse(l.config().tokenToHolders);
        launchpad.injectFees(poolId, 1000e18, 0);
        l.distribute();
        assertEq(l.totalTokenBurned(), 500e18);
        assertEq(l.totalTokenToHolders(), 0);
        assertEq(exile.poolInfo(l.exilePoolId()).stakeTotalDistributed, 0);
    }

    /// @dev If Exile refuses the token payout, the tokens stay in the router, the quote side still runs,
    /// and the next distribute pays them out. Nothing is burned by mistake.
    function test_tokenHoldersPayoutFailureRetries() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        p.cfg.tokenToHolders = true;
        Lodestar l = _activate(p);
        launchpad.injectFees(poolId, 1000e18, 1000e6);
        vm.mockCallRevert(
            address(exile), abi.encodeWithSelector(IExile.notifyStakeReward.selector), abi.encode("down")
        );
        vm.expectEmit(false, false, false, true, address(l));
        emit Lodestar.TokenHoldersPayoutFailed(500e18);
        l.distribute();
        assertEq(token.balanceOf(address(l)), 500e18, "tokens wait in the router");
        assertEq(token.allowance(address(l), address(exile)), 0, "approval cleared");
        assertEq(l.totalTokenBurned(), 0);
        assertEq(l.totalHoldersQuote(), 200e6, "the quote side still paid holders");

        vm.clearMockedCalls();
        vm.warp(block.timestamp + 3 hours);
        l.distribute();
        assertEq(token.balanceOf(address(l)), 0);
        assertEq(l.totalTokenToHolders(), 500e18, "paid on the retry");
    }

    /// @dev Switching between burning and paying lockers is a config change, behind the 12 hour timelock.
    function test_tokenRouteChangeWaitsForTheTimelock() public {
        Lodestar l = _activateDefault(false);
        ILodestar.Config memory c = l.config();
        c.tokenToHolders = true;
        vm.prank(dev);
        l.proposeConfig(c);

        launchpad.injectFees(poolId, 1000e18, 0);
        l.distribute();
        assertEq(l.totalTokenBurned(), 500e18, "still burning while the change waits");

        vm.warp(block.timestamp + 12 hours);
        l.executeConfig();
        launchpad.injectFees(poolId, 1000e18, 0);
        l.distribute();
        assertEq(l.totalTokenBurned(), 500e18);
        assertEq(l.totalTokenToHolders(), 500e18, "now paid to lockers");
    }

    /// @dev After a long outage with a dust lock expiring every hour, Exile's pool is more than one catch-up
    /// behind. distribute moves it forward by one bounded poke and parks both holder payouts instead of
    /// walking every hour inside them; the treasury is still paid and the call stays well inside a block.
    /// Each later distribute moves the pool on, and the parked payouts go out once it is current.
    function test_farBehindExileParksHolderPayoutsAndCatchesUp() public {
        (Lodestar l, uint256 id) = _farBehind(false);
        uint256 g = gasleft();
        l.distribute();
        assertLt(g - gasleft(), 20_000_000, "one bounded catch-up, not the whole month");
        assertEq(l.holdersReserve(), 200e6, "quote holder share parked");
        assertEq(token.balanceOf(address(l)), 500e18, "token-side payout parked");
        assertEq(l.totalTreasuryQuote(), 100e6, "treasury still paid");

        // every distribute moves the pool on; once it is current the parked payouts go out
        for (uint256 i; i < 3 && l.holdersReserve() > 0; ++i) {
            l.distribute();
        }
        assertEq(l.holdersReserve(), 0);
        assertEq(token.balanceOf(address(l)), 0);
        assertEq(l.totalHoldersQuote(), 200e6);
        assertEq(l.totalTokenToHolders(), 500e18);
        vm.warp(block.timestamp + 3 days);
        assertApproxEqRel(exile.pendingRewards(id), 200e6, 0.001e18);
        assertApproxEqRel(exile.pendingStakeRewards(id), 500e18, 0.001e18);
    }

    /// @dev A month-long outage with a dust lock expiring every hour, then 1,000 tokens and 1,000 USDC of fees.
    /// `paidBefore` pays one round to lockers before the outage instead, so every hour Exile walks afterwards
    /// writes a fresh reward snapshot, as it does for a live token.
    function _farBehind(bool paidBefore) internal returns (Lodestar l, uint256 id) {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        p.cfg.tokenToHolders = true;
        l = _activate(p);
        uint256 pid = l.exilePoolId();
        id = _lockToken(l, makeAddr("holder"), 1_000e18, 365 days);
        address mallory = makeAddr("mallory");
        token.mint(mallory, 1e18);
        vm.startPrank(mallory);
        token.approve(address(exile), type(uint256).max);
        for (uint256 k; k < 720; ++k) {
            exile.lockERC20(address(token), 2, uint64(block.timestamp + 1 days + k * 1 hours), pid);
        }
        vm.stopPrank();

        if (paidBefore) {
            launchpad.injectFees(poolId, 1000e18, 1000e6);
            l.distribute();
        }
        vm.warp(block.timestamp + 31 days); // nobody distributes or pokes for a month
        if (!paidBefore) launchpad.injectFees(poolId, 1000e18, 1000e6);
    }

    /// @dev Sent with too little gas for the catch-up, the poke runs out inside its try, and EIP-150's held-back
    /// 1/64 used to be enough to finish with the payouts parked and the pool not moved at all, which is where a
    /// wallet's gas estimate lands. Now every gas limit either reverts or moves the pool on. Measured cold, as
    /// a fresh transaction would run.
    function test_everyGasLimitRevertsOrMovesExileOn() public {
        (Lodestar l,) = _farBehind(true);
        uint256 pid = l.exilePoolId();
        uint64 cursor = _exileCursor(pid);
        assertLt(cursor, block.timestamp - 30 days, "precondition: a month behind");
        uint256 snap = vm.snapshotState();
        _coolAll(l);
        uint256 g = gasleft();
        exile.poke(pid, l.EXILE_CATCH_UP());
        uint256 pokeGas = g - gasleft();
        vm.revertToState(snap);

        uint256 starved;
        for (uint256 i = 30; i <= 110; i += 4) {
            snap = vm.snapshotState();
            _coolAll(l);
            (bool ok, bytes memory ret) = address(l).call{gas: pokeGas * i / 100}(abi.encodeCall(Lodestar.distribute, ()));
            if (ok) {
                assertGt(_exileCursor(pid), cursor, "a distribute that succeeds moves the pool on");
            } else if (ret.length == 4 && bytes4(ret) == Lodestar.CatchUpOutOfGas.selector) {
                ++starved;
            }
            vm.revertToState(snap);
        }
        assertGt(starved, 0, "the starved limits revert with CatchUpOutOfGas");

        l.distribute(); // with enough gas the pool moves on
        assertGt(_exileCursor(pid), cursor);
    }

    /// @dev Marks every contract distribute touches cold again (EIP-2929), as at the start of a transaction.
    function _coolAll(Lodestar l) internal {
        address[8] memory a = [
            address(l),
            address(exile),
            address(token),
            address(usdc),
            address(sandfall),
            address(launchpad),
            address(pool),
            address(mockSwapper)
        ];
        for (uint256 i; i < a.length; ++i) {
            vm.cool(a[i]);
        }
    }

    /// @dev Exile's processed-hour cursor for a pool, read from storage (`_pools` is slot 1; `cursor` sits after
    /// `lastUpdate` in the struct's fourth slot).
    function _exileCursor(uint256 pid) internal view returns (uint64) {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(pid, uint256(1)))) + 3);
        return uint64(uint256(vm.load(address(exile), slot)) >> 64);
    }

    /// @dev A poke that fails for any other reason doesn't stop distribute: the payouts park and the treasury
    /// and buyback still run.
    function test_catchUpThatFailsForAnotherReasonParks() public {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        p.cfg.tokenToHolders = true;
        Lodestar l = _activate(p);
        launchpad.injectFees(poolId, 1000e18, 1000e6);
        vm.mockCallRevert(address(exile), abi.encodeWithSelector(exile.poke.selector), "stuck");
        l.distribute();
        assertEq(l.holdersReserve(), 200e6, "holder share parked");
        assertEq(token.balanceOf(address(l)), 500e18, "token-side payout parked");
        assertEq(l.totalTreasuryQuote(), 100e6, "treasury still paid");
        assertGt(l.totalBuybackQuote(), 0, "buyback still ran");
    }

    // ---------------------------------------------------------------- 15. upgrade to a newer Lodestar

    /// @dev Activated with the creator role locked for good, the box ticked by default on the site.
    function _activateForever() internal returns (Lodestar l) {
        LodestarFactory.DeployParams memory p = _params(token, 4_000, 4_000, 2_000, address(mockSwapper), false);
        p.creatorLockUntil = type(uint64).max;
        l = _activate(p);
        assertEq(l.creatorLockedUntil(), type(uint64).max);
    }

    function _successor() internal returns (address next, address router) {
        router = makeAddr("v2 router");
        next = address(new MockSuccessorFactory(router));
        factory.setSuccessor(next); // this test contract deployed the factory, so it is the owner
    }

    function test_upgradeNeedsASuccessor() public {
        Lodestar l = _activateForever();
        vm.prank(dev);
        vm.expectRevert(Lodestar.NoSuccessor.selector);
        l.proposeUpgrade();
        // a successor that has nowhere for this token is no successor either
        factory.setSuccessor(address(new MockSuccessorFactory(address(0))));
        vm.prank(dev);
        vm.expectRevert(Lodestar.NoSuccessor.selector);
        l.proposeUpgrade();
    }

    function test_onlyOwnerNamesSuccessorAndOnlyStewardProposes() public {
        Lodestar l = _activateForever();
        vm.startPrank(trader);
        vm.expectRevert(LodestarFactory.OnlyOwner.selector);
        factory.setSuccessor(trader);
        vm.stopPrank();
        vm.expectRevert(LodestarFactory.ZeroAddress.selector);
        factory.setSuccessor(address(factory));

        _successor();
        vm.startPrank(trader);
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.proposeUpgrade();
        vm.expectRevert(Lodestar.OnlySteward.selector);
        l.cancelUpgrade();
        vm.stopPrank();
    }

    /// @dev The forever lock still blocks every other hand-off; the proposed move waits 7 days, then anyone
    /// can start it, and the new router finishes it on Ascend.
    function test_upgradeWaitsSevenDaysThenMovesTheRole() public {
        Lodestar l = _activateForever();
        (address next, address router) = _successor();
        vm.prank(dev);
        vm.expectEmit(address(l));
        emit Lodestar.UpgradeProposed(next, router, uint64(block.timestamp + 7 days));
        l.proposeUpgrade();
        assertEq(l.upgradeTarget(), router);

        vm.prank(dev);
        vm.expectRevert(Lodestar.CreatorRoleIsLocked.selector);
        l.transferCreatorOut(trader);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(Lodestar.TimelockActive.selector);
        l.executeUpgrade();

        vm.warp(block.timestamp + 1);
        vm.prank(trader);
        l.executeUpgrade();
        assertEq(launchpad.pendingCreator(poolId), router);
        assertEq(l.upgradeEta(), 0, "one move, then the proposal is spent");
        vm.expectRevert(Lodestar.NoPendingUpgrade.selector);
        l.executeUpgrade();

        vm.prank(router);
        launchpad.acceptCreator(poolId);
        assertEq(launchpad.poolCreator(poolId), router);
        assertFalse(l.isCreator());
    }

    /// @dev Until the new router accepts, the steward can still call the move off and the role stays put.
    function test_stewardCanStopAnExecutedUpgradeBeforeItIsAccepted() public {
        Lodestar l = _activateForever();
        (, address router) = _successor();
        vm.prank(dev);
        l.proposeUpgrade();
        vm.warp(block.timestamp + 7 days);
        l.executeUpgrade();
        vm.prank(dev);
        l.transferCreatorOut(address(0));
        assertEq(launchpad.pendingCreator(poolId), address(0));
        vm.prank(router);
        vm.expectRevert();
        launchpad.acceptCreator(poolId);
        assertTrue(l.isCreator());
    }

    function test_upgradeStopsIfTheSuccessorChanges() public {
        Lodestar l = _activateForever();
        _successor();
        vm.prank(dev);
        l.proposeUpgrade();
        factory.setSuccessor(address(new MockSuccessorFactory(makeAddr("other router"))));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Lodestar.SuccessorChanged.selector);
        l.executeUpgrade();
        factory.setSuccessor(address(0));
        vm.expectRevert(Lodestar.SuccessorChanged.selector);
        l.executeUpgrade();
        assertTrue(l.isCreator());
    }

    function test_upgradeExpires() public {
        Lodestar l = _activateForever();
        _successor();
        vm.prank(dev);
        l.proposeUpgrade();
        vm.warp(block.timestamp + 14 days + 1);
        vm.expectRevert(Lodestar.ProposalExpired.selector);
        l.executeUpgrade();
    }

    function test_cancelUpgrade() public {
        Lodestar l = _activateForever();
        _successor();
        vm.startPrank(dev);
        vm.expectRevert(Lodestar.NoPendingUpgrade.selector);
        l.cancelUpgrade();
        l.proposeUpgrade();
        l.cancelUpgrade();
        vm.stopPrank();
        assertEq(l.upgradeTarget(), address(0));
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(Lodestar.NoPendingUpgrade.selector);
        l.executeUpgrade();
        assertTrue(l.isCreator());
    }
}
