// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Exile} from "../src/Exile.sol";
import {Sandfall} from "../src/Sandfall.sol";
import {Lodestar} from "../src/Lodestar.sol";
import {LodestarFactory} from "../src/LodestarFactory.sol";
import {ILodestar} from "../src/interfaces/ILodestar.sol";
import {ISandfall} from "../src/interfaces/ISandfall.sol";
import {IFeeSource} from "../src/interfaces/IFeeSource.sol";
import {MonarchTiers} from "../src/libraries/MonarchTiers.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {
    MockNativeHook,
    MockNativeSource,
    MockNativeSwapper,
    MockDividendToken,
    MockDividendHook
} from "./utils/NativeMocks.sol";

/// @notice Lodestar on a launchpad shaped like Boxa, Kleos and Eleos: fees in native HYPE, one-step or two-step
/// handover, coins that pay holders dividends. The real launchpads are covered by the fork tests.
contract NativeLodestarTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    Exile internal exile;
    Sandfall internal sandfall;
    Lodestar internal impl;
    MockNativeHook internal hook;
    MockNativeSource internal oneStep;
    MockNativeSource internal twoStep;
    LodestarFactory internal factory1; // one-step launchpad
    LodestarFactory internal factory2; // two-step launchpad
    MockDividendToken internal token;
    MockNativeSwapper internal swapper;

    address internal dev = makeAddr("dev");
    address internal treasury = makeAddr("treasury");
    address internal locker = makeAddr("locker");

    function setUp() public {
        vm.warp(1_700_000_000);
        exile = new Exile();
        sandfall = new Sandfall();
        impl = new Lodestar();
        hook = new MockNativeHook();
        oneStep = new MockNativeSource(hook, IFeeSource.Handover.OneStep);
        twoStep = new MockNativeSource(hook, IFeeSource.Handover.TwoStep);
        factory1 = _factory(oneStep);
        factory2 = _factory(twoStep);
        token = new MockDividendToken();
        hook.launch(address(token), dev);
        swapper = new MockNativeSwapper(token);
    }

    function _factory(MockNativeSource s) internal returns (LodestarFactory f) {
        f = new LodestarFactory(address(impl), IFeeSource(address(s)), exile, ISandfall(address(sandfall)), address(0), address(this));
        exile.proposeRegistrar(address(f));
        skip(12 hours);
        exile.addRegistrar(address(f));
    }

    function _params(address swapper_) internal view returns (LodestarFactory.DeployParams memory p) {
        p.token = address(token);
        p.quote = address(0);
        p.cfg = ILodestar.Config({
            burnBps: 2000,
            holdersBps: 5000,
            treasuryBps: 3000,
            swapper: swapper_,
            maxSlippageBps: 300,
            tokenToHolders: false
        });
        p.treasuryRecipient = treasury;
        p.treasuryWindow = 30 days;
        p.tiers = MonarchTiers.defaults();
    }

    function _oneStep(address swapper_) internal returns (Lodestar l) {
        vm.prank(dev);
        l = Lodestar(payable(factory1.deploy(_params(swapper_))));
        vm.prank(dev);
        hook.transferCreator(address(token), address(l));
    }

    function _lock(uint256 poolId, uint256 amount) internal returns (uint256 id) {
        token.mint(locker, amount);
        vm.startPrank(locker);
        token.approve(address(exile), amount);
        id = exile.lockERC20(address(token), amount, uint64(block.timestamp + 30 days), poolId);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- activation

    function test_oneStepDeployThenHandOver() public {
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory1.deploy(_params(address(0)))));
        assertFalse(l.isCreator());
        assertEq(l.steward(), dev);
        assertEq(l.hook(), address(hook));
        assertEq(address(l.quote()), address(0));
        assertEq(l.burnSink(), DEAD);
        vm.prank(dev);
        hook.transferCreator(address(token), address(l));
        assertTrue(l.isCreator());
    }

    function test_oneStepOnlyTheCreatorDeploys() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory1.deploy(_params(address(0)));
    }

    function test_twoStepProposeThenDeployAccepts() public {
        (address predicted,) = factory2.predict(address(token), address(0));
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.TransferCreatorFirst.selector);
        factory2.deploy(_params(address(0)));
        vm.prank(dev);
        hook.propose(address(token), predicted);
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory2.deploy(_params(address(0)))));
        assertEq(address(l), predicted);
        assertTrue(l.isCreator());
        assertEq(hook.pendingOf(address(token)), address(0));
    }

    function test_roleSentBeforeDeployNeedsTheOwner() public {
        (address predicted,) = factory1.predict(address(token), address(0));
        vm.prank(dev);
        hook.transferCreator(address(token), predicted);
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory1.deploy(_params(address(0)));

        vm.prank(dev);
        vm.expectRevert(LodestarFactory.OnlyOwner.selector);
        factory1.rescueDeploy(_params(address(0)), dev);
        vm.expectRevert(LodestarFactory.ZeroAddress.selector);
        factory1.rescueDeploy(_params(address(0)), address(0));

        Lodestar l = Lodestar(payable(factory1.rescueDeploy(_params(address(0)), dev)));
        assertEq(address(l), predicted);
        assertEq(l.steward(), dev);
        assertTrue(l.isCreator());
    }

    function test_rescueOnlyForAStrandedRole() public {
        vm.expectRevert(LodestarFactory.NotStranded.selector);
        factory1.rescueDeploy(_params(address(0)), dev);
        // never on a two-step launchpad, where the creator proves itself by proposing
        (address predicted,) = factory2.predict(address(token), address(0));
        vm.prank(dev);
        hook.transferCreator(address(token), predicted);
        vm.expectRevert(LodestarFactory.NotStranded.selector);
        factory2.rescueDeploy(_params(address(0)), dev);
    }

    /// @dev Audit round 5, L-1: a one-step launchpad lets a creator send the role to any address, including
    /// another coin's router. That router can't hand it back, so the owner deploys the coin's own router and moves
    /// the role into it.
    function test_roleSentToAnotherCoinsRouterIsRescued() public {
        LodestarFactory.DeployParams memory pa = _params(address(0));
        pa.creatorLockUntil = type(uint64).max; // a locked router still passes on a role that isn't its coin's
        vm.prank(dev);
        Lodestar a = Lodestar(payable(factory1.deploy(pa)));
        vm.prank(dev);
        hook.transferCreator(address(token), address(a));

        MockDividendToken other = new MockDividendToken();
        address dev2 = makeAddr("dev2");
        hook.launch(address(other), dev2);
        vm.prank(dev2);
        hook.transferCreator(address(other), address(a)); // the wrong router
        LodestarFactory.DeployParams memory pb = _params(address(0));
        pb.token = address(other);
        vm.prank(dev2);
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory1.deploy(pb);

        // only the factory moves it, never the holding router's steward, and never the router's own role
        vm.prank(dev);
        vm.expectRevert(Lodestar.OnlyFactory.selector);
        a.releaseForeignRole(address(other), dev);
        vm.prank(address(factory1));
        vm.expectRevert(Lodestar.SelfTransfer.selector);
        a.releaseForeignRole(address(token), dev);
        vm.prank(dev2);
        vm.expectRevert(LodestarFactory.OnlyOwner.selector);
        factory1.rescueDeploy(pb, dev2);

        Lodestar b = Lodestar(payable(factory1.rescueDeploy(pb, dev2)));
        (address predicted,) = factory1.predict(address(other), address(0));
        assertEq(address(b), predicted);
        assertEq(b.steward(), dev2);
        assertTrue(b.isCreator(), "the coin's own router holds its role");
        assertTrue(a.isCreator(), "the other router keeps its own");
        assertEq(hook.creatorOf(address(token)), address(a));
    }

    function test_rescueRefusesARoleHeldByAnythingElse() public {
        MockDividendToken other = new MockDividendToken();
        hook.launch(address(other), makeAddr("dev2"));
        LodestarFactory.DeployParams memory pb = _params(address(0));
        pb.token = address(other);
        // a plain wallet, or a contract that isn't one of this factory's routers
        vm.expectRevert(LodestarFactory.NotStranded.selector);
        factory1.rescueDeploy(pb, dev);
        vm.prank(makeAddr("dev2"));
        hook.transferCreator(address(other), address(swapper));
        vm.expectRevert(LodestarFactory.NotStranded.selector);
        factory1.rescueDeploy(pb, dev);
    }

    function test_noListingDeskNoEnrolment() public {
        LodestarFactory.DeployParams memory p = _params(address(0));
        p.enrolListing = true;
        p.listingCap = 1 ether;
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.NoListingDesk.selector);
        factory1.deploy(p);
    }

    function test_holderShareNeedsAKnownClaim() public {
        oneStep.set(2500, address(0), bytes4(0));
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.HoldersSplitActive.selector);
        factory1.deploy(_params(address(0)));

        oneStep.set(2500, address(token), bytes4(keccak256("claimFor(address)")));
        Lodestar l = _oneStep(address(0));
        (uint256 poolId, address target, bytes4 sel) = exile.harvestOf(address(token));
        assertEq(poolId, l.exilePoolId());
        assertEq(target, address(token));
        assertEq(sel, bytes4(keccak256("claimFor(address)")));
    }

    function test_harvestIsSetWheneverTheAdapterKnowsTheClaim() public {
        oneStep.set(0, address(token), bytes4(keccak256("claimRewards(address)")));
        Lodestar l = _oneStep(address(0));
        (uint256 poolId,,) = exile.harvestOf(address(token));
        assertEq(poolId, l.exilePoolId());
    }

    // ---------------------------------------------------------------- routing native fees

    function test_distributeRoutesNativeFees() public {
        Lodestar l = _oneStep(address(0));
        uint256 lockId = _lock(l.exilePoolId(), 1000e18);
        hook.accrue{value: 10 ether}(address(token));
        (, uint256 quoteTotal, uint256 burnQ, uint256 holdQ, uint256 treasQ) = l.previewDistribute();
        assertEq(quoteTotal, 10 ether);
        assertEq(burnQ, 2 ether);
        assertEq(holdQ, 5 ether);
        assertEq(treasQ, 3 ether);

        l.distribute();
        assertEq(oneStep.pokes(), 1, "the router pokes the price source first");
        assertEq(hook.owedOf(address(token)), 0);
        assertEq(l.totalHoldersQuote(), 5 ether);
        assertEq(l.totalTreasuryQuote(), 3 ether);
        assertEq(l.buybackReserve(), 2 ether, "no swapper: the buyback share waits");
        assertEq(address(l).balance, 2 ether);
        assertEq(address(exile).balance, 5 ether);
        assertEq(address(sandfall).balance, 3 ether);

        skip(3 days);
        uint256 before = locker.balance;
        vm.prank(locker);
        exile.claimRewards(lockId);
        assertApproxEqAbs(locker.balance - before, 5 ether, 1e6);
        uint256 streamId = l.treasuryStreamId();
        uint256 vested = sandfall.claimable(streamId);
        assertGt(vested, 0);
        uint256 tb = treasury.balance;
        vm.prank(treasury);
        sandfall.claim(streamId);
        assertEq(treasury.balance - tb, vested);
    }

    function test_hypeSentDirectlyIsRoutedToo() public {
        Lodestar l = _oneStep(address(0));
        (bool ok,) = address(l).call{value: 1 ether}("");
        assertTrue(ok);
        l.distribute();
        assertEq(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), 1 ether);
    }

    function test_nativeBuybackBurns() public {
        Lodestar l = _oneStep(address(swapper));
        hook.accrue{value: 10 ether}(address(token));
        l.distribute();
        assertEq(l.totalBuybackQuote(), 2 ether);
        assertEq(l.totalBuybackTokensBurned(), 2 ether, "1:1 price, no impact");
        assertEq(token.balanceOf(DEAD), 2 ether);
        assertEq(l.buybackReserve(), 0);
    }

    function test_buybackFloorCountsTheSwapCost() public {
        Lodestar l = _oneStep(address(swapper));
        // 1% tax + 3% slippage: 1 HYPE must buy at least 0.96 tokens at the 1:1 reference
        assertEq(l.quoteMinOut(1 ether, 300), 0.96 ether);
        oneStep.setMarket(uint160(1 << 96), uint160(1 << 96), 1e24, 400);
        assertEq(l.quoteMinOut(1 ether, 300), 0.93 ether);
    }

    function test_buybackWaitsWhenTheTaxIsTooHigh() public {
        Lodestar l = _oneStep(address(swapper));
        oneStep.setMarket(uint160(1 << 96), uint160(1 << 96), 1e24, 501);
        hook.accrue{value: 10 ether}(address(token));
        vm.expectEmit(address(l));
        emit Lodestar.BuybackSkipped(0, 0);
        l.distribute();
        assertEq(l.buybackReserve(), 2 ether);
        assertEq(l.totalBuybackTokensBurned(), 0);
    }

    function test_buybackWaitsWithoutAnAverage() public {
        Lodestar l = _oneStep(address(swapper));
        oneStep.setMarket(uint160(1 << 96), 0, 1e24, 100);
        hook.accrue{value: 10 ether}(address(token));
        l.distribute();
        assertEq(l.buybackReserve(), 2 ether);
    }

    function test_aShortBuybackIsRolledBack() public {
        Lodestar l = _oneStep(address(swapper));
        swapper.setShort(1000); // pays 10% less than it promised the router
        hook.accrue{value: 10 ether}(address(token));
        l.distribute();
        assertEq(l.buybackReserve(), 2 ether, "the HYPE stays in reserve");
        assertEq(token.balanceOf(DEAD), 0);
    }

    // ---------------------------------------------------------------- the call-target rule

    function test_launchpadCallsOnlyGoToTheStoredHook() public {
        Lodestar l = _oneStep(address(0));
        hook.accrue{value: 1 ether}(address(token));
        oneStep.setCallTarget(makeAddr("elsewhere"));
        // distribute keeps going: the claim is skipped and retried next time
        vm.expectEmit(address(l));
        emit Lodestar.ClaimFailed();
        l.distribute();
        assertEq(hook.owedOf(address(token)), 1 ether);
        // steward actions revert outright
        vm.prank(dev);
        vm.expectRevert(Lodestar.BadCallTarget.selector);
        l.transferCreatorOut(makeAddr("next"));
        oneStep.setCallTarget(address(0));
        l.distribute();
        assertEq(hook.owedOf(address(token)), 0);
    }

    function test_acceptRevertsWithoutAPendingRole() public {
        (address predicted,) = factory2.predict(address(token), address(0));
        vm.prank(dev);
        hook.propose(address(token), predicted);
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory2.deploy(_params(address(0)))));
        vm.expectRevert(Lodestar.CreatorNotPending.selector);
        l.acceptCreator();
    }

    // ---------------------------------------------------------------- handing the role on

    function test_oneStepTransferOutMovesAtOnce() public {
        Lodestar l = _oneStep(address(0));
        address next = makeAddr("next");
        vm.prank(dev);
        l.transferCreatorOut(next);
        assertEq(hook.creatorOf(address(token)), next);
        // cancelling is a no-op on a one-step launchpad
        vm.prank(next);
        hook.transferCreator(address(token), address(l));
        vm.prank(dev);
        l.transferCreatorOut(address(0));
        assertTrue(l.isCreator());
    }

    function test_lockBlocksTransferOut() public {
        LodestarFactory.DeployParams memory p = _params(address(0));
        p.creatorLockUntil = type(uint64).max;
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory1.deploy(p)));
        vm.prank(dev);
        hook.transferCreator(address(token), address(l));
        vm.prank(dev);
        vm.expectRevert(Lodestar.CreatorRoleIsLocked.selector);
        l.transferCreatorOut(makeAddr("next"));
    }

    function test_twoStepLockWaitsForNoPendingHandOff() public {
        (address predicted,) = factory2.predict(address(token), address(0));
        vm.prank(dev);
        hook.propose(address(token), predicted);
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory2.deploy(_params(address(0)))));
        vm.prank(dev);
        l.transferCreatorOut(makeAddr("next"));
        vm.prank(dev);
        vm.expectRevert(Lodestar.CreatorTransferPending.selector);
        l.lockCreatorRole(uint64(block.timestamp + 365 days));
        vm.prank(dev);
        l.transferCreatorOut(address(0));
        vm.prank(dev);
        l.lockCreatorRole(uint64(block.timestamp + 365 days));
    }

    /// @dev One-step upgrade: the steward deploys the new router during the notice, then the role moves at once.
    function test_oneStepUpgrade() public {
        LodestarFactory.DeployParams memory p = _params(address(0));
        p.creatorLockUntil = type(uint64).max;
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory1.deploy(p)));
        vm.prank(dev);
        hook.transferCreator(address(token), address(l));

        LodestarFactory next = _factory(oneStep);
        factory1.setSuccessor(address(next));
        vm.prank(dev);
        l.proposeUpgrade();
        (address target,) = next.predict(address(token), address(0));
        assertEq(l.upgradeTarget(), target);

        skip(7 days);
        // the new router has to exist before the role can move
        vm.expectRevert(Lodestar.NoSuccessor.selector);
        l.executeUpgrade();

        // a stranger can't deploy it, the steward can
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        next.deploy(_params(address(0)));
        vm.prank(dev);
        Lodestar l2 = Lodestar(payable(next.deploy(_params(address(0)))));
        assertEq(address(l2), target);

        l.executeUpgrade();
        assertTrue(l2.isCreator());
        assertFalse(l.isCreator());
    }

    function test_twoStepUpgradeNeedsTheNewRouterToAccept() public {
        (address predicted,) = factory2.predict(address(token), address(0));
        vm.prank(dev);
        hook.propose(address(token), predicted);
        LodestarFactory.DeployParams memory p = _params(address(0));
        p.creatorLockUntil = type(uint64).max;
        vm.prank(dev);
        Lodestar l = Lodestar(payable(factory2.deploy(p)));

        LodestarFactory next = _factory(twoStep);
        factory2.setSuccessor(address(next));
        vm.prank(dev);
        l.proposeUpgrade();
        skip(7 days);
        l.executeUpgrade(); // proposes the new router, which doesn't exist yet
        (address target,) = next.predict(address(token), address(0));
        assertEq(hook.pendingOf(address(token)), target);

        vm.prank(dev);
        Lodestar l2 = Lodestar(payable(next.deploy(_params(address(0)))));
        assertTrue(l2.isCreator());
    }

    // ---------------------------------------------------------------- dividends through Exile

    function test_dividendsOnLockedCoinsReachLockers() public {
        oneStep.set(3000, address(token), bytes4(keccak256("claimFor(address)")));
        Lodestar l = _oneStep(address(0));
        uint256 lockId = _lock(l.exilePoolId(), 1000e18);
        token.credit{value: 4 ether}(address(exile));
        assertEq(exile.harvest(address(token)), 4 ether);
        skip(3 days);
        uint256 before = locker.balance;
        vm.prank(locker);
        exile.claimRewards(lockId);
        assertApproxEqAbs(locker.balance - before, 4 ether, 1e6);
    }

    function test_hookSideDividendsReachLockers() public {
        MockDividendHook dh = new MockDividendHook();
        oneStep.set(3000, address(dh), bytes4(keccak256("claimRewards(address,address)")));
        Lodestar l = _oneStep(address(0));
        uint256 lockId = _lock(l.exilePoolId(), 1000e18);
        dh.credit{value: 2 ether}(address(token), address(exile));
        assertEq(exile.harvest(address(token)), 2 ether);
        skip(3 days);
        vm.prank(locker);
        assertApproxEqAbs(exile.claimRewards(lockId), 2 ether, 1e6);
    }

    receive() external payable {}
}
