// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Exile} from "../src/Exile.sol";
import {IExile} from "../src/interfaces/IExile.sol";
import {MonarchTiers} from "../src/libraries/MonarchTiers.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockDividendToken, MockDividendHook, NoReceive} from "./utils/NativeMocks.sol";

/// @notice Exile's native HYPE reward pools, the dividend harvest and the registrar timelock.
contract ExileNativeTest is Test {
    Exile internal exile;
    MockDividendToken internal token;
    MockERC20 internal usdc;
    address internal registrar = makeAddr("registrar");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes4 internal constant CLAIM_FOR = bytes4(keccak256("claimFor(address)"));
    bytes4 internal constant CLAIM_REWARDS_FOR = bytes4(keccak256("claimRewards(address)"));
    bytes4 internal constant CLAIM_REWARDS_TO = bytes4(keccak256("claimRewards(address,address)"));

    function setUp() public {
        vm.warp(1_700_000_000);
        exile = new Exile();
        token = new MockDividendToken();
        usdc = new MockERC20("USDC", "USDC", 6);
        exile.proposeRegistrar(registrar);
        skip(12 hours);
        exile.addRegistrar(registrar);
    }

    function _pool(address rewardToken) internal returns (uint256) {
        return exile.createPool(address(token), rewardToken, MonarchTiers.defaults(), address(this));
    }

    function _lock(address who, uint256 poolId, uint256 amount, uint64 duration) internal returns (uint256 id) {
        token.mint(who, amount);
        vm.startPrank(who);
        token.approve(address(exile), amount);
        id = exile.lockERC20(address(token), amount, uint64(block.timestamp) + duration, poolId);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- native reward pools

    function test_nativePoolPaysHype() public {
        uint256 poolId = _pool(address(0));
        uint256 a = _lock(alice, poolId, 100e18, 30 days);
        uint256 b = _lock(bob, poolId, 100e18, 7 days); // half the multiplier
        exile.notifyReward{value: 3 ether}(poolId, 3 ether);
        skip(3 days);
        vm.prank(alice);
        uint256 pa = exile.claimRewards(a);
        vm.prank(bob);
        uint256 pb = exile.claimRewards(b);
        assertApproxEqAbs(pa, 2 ether, 1e6);
        assertApproxEqAbs(pb, 1 ether, 1e6);
        assertEq(alice.balance, pa);
        assertEq(bob.balance, pb);
    }

    function test_nativeNotifyChecksValue() public {
        uint256 poolId = _pool(address(0));
        vm.expectRevert(Exile.WrongValue.selector);
        exile.notifyReward{value: 1 ether}(poolId, 2 ether);
        uint256 erc20Pool = _pool(address(usdc));
        usdc.mint(address(this), 1e6);
        usdc.approve(address(exile), 1e6);
        vm.expectRevert(Exile.WrongValue.selector);
        exile.notifyReward{value: 1}(erc20Pool, 1e6);
        exile.notifyReward(erc20Pool, 1e6);
    }

    function test_claimToAnAddressThatRefusesHypeFails() public {
        uint256 poolId = _pool(address(0));
        uint256 a = _lock(alice, poolId, 100e18, 30 days);
        exile.notifyReward{value: 1 ether}(poolId, 1 ether);
        skip(3 days);
        address sink = address(new NoReceive());
        vm.prank(alice);
        vm.expectRevert(Exile.PayoutFailed.selector);
        exile.claimRewardsTo(a, sink);
        // and the reward is still there for a working address
        vm.prank(alice);
        assertApproxEqAbs(exile.claimRewardsTo(a, bob), 1 ether, 1e6);
    }

    function testFuzz_nativeRewardsNeverExceedDeposits(uint96 r1, uint96 r2, uint32 gap) public {
        uint256 poolId = _pool(address(0));
        uint256 a = _lock(alice, poolId, 100e18, 30 days);
        uint256 b = _lock(bob, poolId, 37e18, 3 days);
        uint256 d1 = bound(r1, 1, 1_000 ether);
        uint256 d2 = bound(r2, 1, 1_000 ether);
        vm.deal(address(this), d1 + d2);
        exile.notifyReward{value: d1}(poolId, d1);
        skip(bound(gap, 0, 10 days));
        exile.notifyReward{value: d2}(poolId, d2);
        skip(40 days);
        while (!exile.poke(poolId, 500)) {}
        vm.prank(alice);
        uint256 pa = exile.claimRewards(a);
        vm.prank(bob);
        uint256 pb = exile.claimRewards(b);
        assertLe(pa + pb, d1 + d2);
        assertEq(address(exile).balance, d1 + d2 - pa - pb);
    }

    // ---------------------------------------------------------------- harvest

    function test_onlyRegistrarsSetHarvests() public {
        uint256 poolId = _pool(address(0));
        vm.expectRevert(Exile.NotRegistrar.selector);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_FOR);
    }

    function test_harvestShapesAreFixed() public {
        uint256 poolId = _pool(address(0));
        uint256 erc20Pool = _pool(address(usdc));
        MockDividendHook hook = new MockDividendHook();
        vm.startPrank(registrar);
        // the pool must be this token's and pay HYPE
        vm.expectRevert(Exile.InvalidHarvest.selector);
        exile.setHarvest(address(usdc), poolId, address(usdc), CLAIM_FOR);
        vm.expectRevert(Exile.InvalidHarvest.selector);
        exile.setHarvest(address(token), erc20Pool, address(token), CLAIM_FOR);
        // one-argument claims are on the token itself
        vm.expectRevert(Exile.InvalidHarvest.selector);
        exile.setHarvest(address(token), poolId, address(hook), CLAIM_FOR);
        vm.expectRevert(Exile.InvalidHarvest.selector);
        exile.setHarvest(address(token), poolId, address(hook), CLAIM_REWARDS_FOR);
        // the two-argument claim is on another contract
        vm.expectRevert(Exile.InvalidHarvest.selector);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_REWARDS_TO);
        vm.expectRevert(Exile.InvalidHarvest.selector);
        exile.setHarvest(address(token), poolId, makeAddr("eoa"), CLAIM_REWARDS_TO);
        // nothing else
        vm.expectRevert(Exile.InvalidHarvest.selector);
        exile.setHarvest(address(token), poolId, address(token), IERC20Like.transfer.selector);
        vm.expectRevert(Exile.InvalidHarvest.selector);
        exile.setHarvest(address(token), poolId, address(token), bytes4(keccak256("withdraw(address)")));

        exile.setHarvest(address(token), poolId, address(token), CLAIM_FOR);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_REWARDS_FOR);
        exile.setHarvest(address(token), poolId, address(hook), CLAIM_REWARDS_TO);
        vm.stopPrank();
    }

    function test_harvestTokenClaimFor() public {
        uint256 poolId = _pool(address(0));
        vm.prank(registrar);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_FOR);
        uint256 a = _lock(alice, poolId, 100e18, 30 days);
        token.credit{value: 2 ether}(address(exile));
        assertEq(exile.harvest(address(token)), 2 ether);
        assertEq(token.dividendOf(address(exile)), 0);
        assertEq(exile.harvest(address(token)), 0, "nothing new");
        skip(3 days);
        vm.prank(alice);
        assertApproxEqAbs(exile.claimRewards(a), 2 ether, 1e6);
    }

    function test_harvestTokenClaimRewardsFromExile() public {
        uint256 poolId = _pool(address(0));
        vm.prank(registrar);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_REWARDS_FOR);
        _lock(alice, poolId, 100e18, 30 days);
        token.credit{value: 1 ether}(address(exile));
        // a stranger can't claim Exile's dividends on the token, but harvest (Exile calling) can
        vm.expectRevert(bytes("holder only"));
        token.claimRewards(address(exile));
        assertEq(exile.harvest(address(token)), 1 ether);
    }

    function test_harvestThroughTheHook() public {
        MockDividendHook hook = new MockDividendHook();
        uint256 poolId = _pool(address(0));
        vm.prank(registrar);
        exile.setHarvest(address(token), poolId, address(hook), CLAIM_REWARDS_TO);
        _lock(alice, poolId, 100e18, 30 days);
        hook.credit{value: 3 ether}(address(token), address(exile));
        assertEq(exile.harvest(address(token)), 3 ether);
        assertEq(hook.dividendOf(address(token), address(exile)), 0);
    }

    function test_pushedDividendsJoinTheNextHarvest() public {
        uint256 poolId = _pool(address(0));
        vm.prank(registrar);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_FOR);
        _lock(alice, poolId, 100e18, 30 days);
        token.credit{value: 1 ether}(address(exile));
        token.claimFor(address(exile)); // anyone pushes it
        assertEq(exile.unattributed(address(token)), 1 ether);
        token.credit{value: 0.5 ether}(address(exile));
        assertEq(exile.harvest(address(token)), 1.5 ether);
        assertEq(exile.unattributed(address(token)), 0);
    }

    function test_aFailingClaimStillPaysWhatWasPushed() public {
        uint256 poolId = _pool(address(0));
        vm.prank(registrar);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_FOR);
        _lock(alice, poolId, 100e18, 30 days);
        token.credit{value: 1 ether}(address(exile));
        token.claimFor(address(exile));
        token.setBroken(true);
        assertEq(exile.harvest(address(token)), 1 ether);
    }

    function test_hypeFromOthersIsNotHarvested() public {
        uint256 poolId = _pool(address(0));
        vm.prank(registrar);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_FOR);
        (bool ok,) = address(exile).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(exile.unattributed(address(this)), 1 ether);
        assertEq(exile.harvest(address(token)), 0);
    }

    /// @dev Audit round 5, L-2: the harvest pays the dividends on all of Exile's balance of a coin to one pool, so
    /// Exile only takes locks of that coin in that pool.
    function test_aHarvestedCoinOnlyLocksInItsHarvestPool() public {
        uint256 poolId = _pool(address(0));
        uint256 otherPool = _pool(address(0));
        _lock(alice, 0, 1e18, 30 days); // before the harvest, plain locks still work
        vm.prank(registrar);
        exile.setHarvest(address(token), poolId, address(token), CLAIM_FOR);

        token.mint(bob, 2e18);
        vm.startPrank(bob);
        token.approve(address(exile), 2e18);
        vm.expectRevert(Exile.HarvestPoolOnly.selector);
        exile.lockERC20(address(token), 1e18, uint64(block.timestamp + 30 days), 0);
        vm.expectRevert(Exile.HarvestPoolOnly.selector);
        exile.lockERC20(address(token), 1e18, uint64(block.timestamp + 30 days), otherPool);
        exile.lockERC20(address(token), 1e18, uint64(block.timestamp + 30 days), poolId);
        vm.stopPrank();

        // other coins are unaffected
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(exile), 1e6);
        exile.lockERC20(address(usdc), 1e6, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();
    }

    function test_harvestNeedsAHarvestPool() public {
        vm.expectRevert(Exile.NoHarvest.selector);
        exile.harvest(address(token));
    }

    // ---------------------------------------------------------------- owner and registrars

    function test_registrarTimelock() public {
        address r = makeAddr("r2");
        vm.prank(alice);
        vm.expectRevert(Exile.OnlyOwner.selector);
        exile.proposeRegistrar(r);
        vm.expectRevert(Exile.NoPendingRegistrar.selector);
        exile.addRegistrar(r);
        exile.proposeRegistrar(r);
        skip(12 hours - 1);
        vm.expectRevert(Exile.TimelockActive.selector);
        exile.addRegistrar(r);
        skip(1);
        exile.addRegistrar(r);
        assertTrue(exile.isRegistrar(r));
        exile.removeRegistrar(r);
        assertFalse(exile.isRegistrar(r));
    }

    function test_registrarProposalExpires() public {
        address r = makeAddr("r2");
        exile.proposeRegistrar(r);
        skip(12 hours + 7 days + 1);
        vm.expectRevert(Exile.ProposalExpired.selector);
        exile.addRegistrar(r);
    }

    function test_ownerHandsOverInTwoSteps() public {
        exile.transferOwner(alice);
        assertEq(exile.owner(), address(this));
        vm.prank(bob);
        vm.expectRevert(Exile.NotPendingOwner.selector);
        exile.acceptOwner();
        vm.prank(alice);
        exile.acceptOwner();
        assertEq(exile.owner(), alice);
        vm.expectRevert(Exile.OnlyOwner.selector);
        exile.proposeRegistrar(bob);
    }
}

interface IERC20Like {
    function transfer(address, uint256) external returns (bool);
}
