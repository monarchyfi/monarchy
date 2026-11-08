// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {ElysPumpFeeSource} from "../../src/sources/ElysPumpFeeSource.sol";
import {V4FeeSource} from "../../src/sources/V4FeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {IElysPumpHook} from "../../src/interfaces/ILaunchpadHooks.sol";

interface IElysPumpCoin {
    function claim() external returns (uint256);
    function rewardExcluded(address holder) external view returns (bool);
}

/// @notice Lodestar on ElysPump (elysp.com) against its real v2 and v3 hooks on an Elysium mainnet fork.
contract ElysPumpForkTest is ForkBase {
    address internal constant HOOK_V2 = 0xe11CaFA5901B0aaB51eB78251488400f9e4320Cc;
    address internal constant HOOK_V3 = 0xBAcF71Bf02b8cfE171853C5eC4A060Ba2Ac1E0cc;
    address internal constant PM_V2 = 0x5fb015a49f5b35073f9Ce01C2aDb287A75F89600; // ElysPump's own pool manager
    address internal constant PM_V3 = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1; // the official one

    // v2, 1% fee: 50% of the creator side to the receiver, 25% holders, 25% buyback
    address internal constant MIX = 0x949a66AC7d58eC0a64B1414A9471F1083143FdAB;
    // v2, ElysPump's own coin, 1% fee, all of the creator side to the receiver
    address internal constant ELYSP = 0x7a7AE0e715867fc3b0055192624982017328c60B;
    // v3, 1% fee, all to the receiver
    address internal constant V3_ALL = 0xEaE5D9940FA64D3F7c2e1570dAA48f3EEFD80c2b;
    // v3, 1% fee, 50% receiver, 25% holders, 25% buyback
    address internal constant V3_MIX = 0xbdE53aCbC56F5dE32473528A6e028A363819f7B1;
    // v2, receiver share 0 (50% holders, 50% buyback): nothing to route
    address internal constant BLOB = 0x9a9815Af521149E8D982791703A31bca2F95f534;
    // v2, quoted in KNTQ
    address internal constant KNTQ_COIN = 0xfe7cf2348cDD998f32346CB5FD2f8C28326184da;
    // a Kleos coin: its hook isn't ElysPump's
    address internal constant KLEOS_COIN = 0x5e5Df82d563FCF36b6f853c4D09f89e2d18825B4;

    ElysPumpFeeSource internal source;
    LodestarFactory internal factory;

    function setUp() public {
        if (!_fork()) return;
        address[] memory hooks = new address[](2);
        uint8[] memory kinds = new uint8[](2);
        (hooks[0], kinds[0]) = (HOOK_V2, 1);
        (hooks[1], kinds[1]) = (HOOK_V3, 1);
        source = new ElysPumpFeeSource(observer, address(this), hooks, kinds);
        factory = _factory(IFeeSource(address(source)));
    }

    function _hook(address coin) internal view returns (address hook) {
        (hook,) = source.hookOf(coin);
    }

    function _owedTo(address coin, address who) internal view returns (uint256) {
        (, uint256 q) = source.owed(coin, bytes32(0), who);
        return q;
    }

    /// @dev ElysPump is one-step: deploy, then `setFeeReceiver(coin, router)` from the receiver.
    function _activate(address coin, address swapper) internal returns (Lodestar l) {
        address dev = source.creator(coin, bytes32(0));
        vm.prank(dev);
        l = Lodestar(payable(factory.deploy(_params(coin, swapper))));
        address hook = _hook(coin);
        vm.prank(dev);
        IElysPumpHook(hook).setFeeReceiver(coin, address(l));
        assertTrue(l.isCreator(), "router holds the role");
    }

    function test_registry() public view {
        (uint8 k2, address pm2) = source.hooks(HOOK_V2);
        (uint8 k3, address pm3) = source.hooks(HOOK_V3);
        assertEq(k2, 1);
        assertEq(k3, 1);
        assertEq(pm2, PM_V2);
        assertEq(pm3, PM_V3);
    }

    function test_resolveAndViews() public view {
        (bytes32 id, address hook, bool tokenIs0) = source.resolve(MIX, address(0));
        assertEq(hook, HOOK_V2);
        assertFalse(tokenIs0);
        assertEq(id, keccak256(abi.encode(IElysPumpHook(HOOK_V2).keyOf(MIX))));
        assertEq(IElysPumpHook(HOOK_V2).tokenOfPool(id), MIX);
        (bytes32 id3, address hook3,) = source.resolve(V3_ALL, address(0));
        assertEq(hook3, HOOK_V3);
        assertEq(IElysPumpHook(HOOK_V3).tokenOfPool(id3), V3_ALL);
        assertEq(source.swapCostBps(MIX, id), 100);
        assertEq(source.holdersShareBps(MIX, id), 2500);
        assertEq(source.holdersShareBps(ELYSP, bytes32(0)), 0);
        assertEq(source.receiverShareBps(MIX), 5000);
        assertEq(source.receiverShareBps(BLOB), 0);
        (address target, bytes4 sel) = source.dividendClaim(MIX);
        assertEq(target, MIX);
        assertEq(sel, bytes4(keccak256("claim()")));
        assertEq(source.burnSink(MIX), DEAD);
        assertTrue(source.handover() == IFeeSource.Handover.OneStep);
        (uint160 spot,, uint128 liq) = source.prices(V3_ALL, id3);
        assertGt(spot, 0);
        assertGt(liq, 0);
    }

    function test_refusesWhatItCantRoute() public {
        vm.expectRevert(ElysPumpFeeSource.NoReceiverShare.selector);
        source.resolve(BLOB, address(0));
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(KNTQ_COIN, address(0));
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.receiverShareBps(KNTQ_COIN);
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(MIX, makeAddr("someQuote"));
        vm.expectRevert(V4FeeSource.UnsupportedHook.selector);
        source.resolve(KLEOS_COIN, address(0));

        address dev = source.creator(BLOB, bytes32(0));
        vm.prank(dev);
        vm.expectRevert(ElysPumpFeeSource.NoReceiverShare.selector);
        factory.deploy(_params(BLOB, address(0)));
    }

    /// @dev ElysPump keys receiver fees by address: the dev keeps what they earned before handing over.
    function _claimAndDistribute(address coin) internal returns (Lodestar l) {
        address dev = source.creator(coin, bytes32(0));
        uint256 devOwed = _owedTo(coin, dev);
        l = _activate(coin, address(0));
        assertEq(_owedTo(coin, dev), devOwed, "the dev's earlier fees stay the dev's");
        assertEq(_owedTo(coin, address(l)), 0);

        _volume(source, coin, 0.5 ether, 10);
        uint256 owedQ = _owedTo(coin, address(l));
        assertGt(owedQ, 0, "fees accrue to the router");
        l.distribute();
        assertEq(_owedTo(coin, address(l)), 0, "claim(HYPE) paid the router");
        assertEq(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), owedQ);
        assertEq(l.totalHoldersQuote(), owedQ * HOLDERS_BPS / 10_000);
    }

    function test_v2_claimAndDistribute() public {
        Lodestar l = _claimAndDistribute(ELYSP);
        // 5 HYPE of buys at 1%: 30% to the platform, all of the rest to the receiver
        assertApproxEqAbs(
            l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), 0.035 ether, 10
        );
    }

    function test_v2_mixedSplit_claimAndDistribute() public {
        Lodestar l = _claimAndDistribute(MIX);
        // the receiver's half of the creator side: 5 HYPE * 1% * 70% * 50%
        assertApproxEqAbs(
            l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), 0.0175 ether, 10
        );
    }

    function test_v3_claimAndDistribute() public {
        _claimAndDistribute(V3_ALL);
    }

    function test_buybackThroughTheV3Pool() public {
        Lodestar l = _activate(V3_ALL, address(_swapper(PM_V3)));
        _volume(source, V3_ALL, 0.5 ether, 10);
        uint256 deadBefore = IERC20(V3_ALL).balanceOf(DEAD);
        l.distribute();
        skip(31 minutes);
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0, "bought back on ElysPump's pool, net of its buy fee");
        assertEq(IERC20(V3_ALL).balanceOf(DEAD) - deadBefore, l.totalBuybackTokensBurned());
    }

    function test_buybackThroughTheV2Pool() public {
        Lodestar l = _activate(ELYSP, address(_swapper(PM_V2)));
        _volume(source, ELYSP, 0.5 ether, 10);
        uint256 deadBefore = IERC20(ELYSP).balanceOf(DEAD);
        l.distribute();
        skip(31 minutes);
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0, "bought back on ElysPump's own pool manager");
        assertEq(IERC20(ELYSP).balanceOf(DEAD) - deadBefore, l.totalBuybackTokensBurned());
    }

    /// @dev Locked coins earn the coin's own holder dividends; Exile claims them with `claim()` and passes them on.
    /// The hook keeps the holders' share until a `flush(coin)`, which a holder's `claim()` runs first, so the
    /// harvest needs no separate call.
    function _harvest(address coin) internal {
        Lodestar l = _activate(coin, address(0));
        uint256 poolId = l.exilePoolId();
        (uint256 hPool, address target, bytes4 sel) = exile.harvestOf(coin);
        assertEq(hPool, poolId);
        assertEq(target, coin);
        assertEq(sel, bytes4(keccak256("claim()")));
        assertFalse(IElysPumpCoin(coin).rewardExcluded(address(exile)), "Exile earns like any holder");

        _buy(source, coin, 0.3 ether, locker);
        skip(20 minutes);
        _lock(coin, poolId, IERC20(coin).balanceOf(locker));
        _volume(source, coin, 0.5 ether, 10);
        assertGt(IElysPumpHook(_hook(coin)).holderPending(coin), 0, "the hook holds the holders' share");
        l.distribute();

        uint256 snap = vm.snapshotState();
        vm.prank(address(exile));
        uint256 earned = IElysPumpCoin(coin).claim();
        vm.revertToState(snap);
        assertGt(earned, 0, "Exile earns dividends on locked coins");
        assertEq(exile.harvest(coin), earned, "claim() paid Exile");
        assertEq(IElysPumpHook(_hook(coin)).holderPending(coin), 0, "the claim flushed the holders' share");
        vm.prank(address(exile));
        assertEq(IElysPumpCoin(coin).claim(), 0, "nothing left");

        skip(3 days);
        uint256[] memory ids = exile.lockIdsOf(locker);
        uint256 before = locker.balance;
        vm.prank(locker);
        exile.claimRewards(ids[0]);
        assertApproxEqRel(locker.balance - before, l.totalHoldersQuote() + earned, 1e15);
    }

    function test_harvestOnV2() public {
        _harvest(MIX);
    }

    function test_harvestOnV3() public {
        _harvest(V3_MIX);
    }

    function test_strangerCannotDeploy() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(ELYSP, address(0)));
    }

    function test_onlyTheReceiverMovesTheRole() public {
        address hook = _hook(ELYSP);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        IElysPumpHook(hook).setFeeReceiver(ELYSP, makeAddr("stranger"));
    }

    function test_stewardHandsTheRoleBack() public {
        Lodestar l = _activate(ELYSP, address(0));
        address next = makeAddr("next");
        vm.prank(l.steward());
        l.transferCreatorOut(next);
        assertEq(source.creator(ELYSP, bytes32(0)), next);
        assertFalse(l.isCreator());
    }

    /// @dev As on Kleos: ELYSP's receiver sends the role to MIX's router. ElysPump keys receiver fees by address, so
    /// MIX's router would collect ELYSP's fees for its own lockers; the owner moves the role into ELYSP's own router.
    function test_roleSentToAnotherCoinsRouterIsRescued() public {
        Lodestar mix = _activate(MIX, address(0));
        address dev = source.creator(ELYSP, bytes32(0));
        address hook = _hook(ELYSP);
        vm.prank(dev);
        IElysPumpHook(hook).setFeeReceiver(ELYSP, address(mix));
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(ELYSP, address(0)));

        Lodestar elysp = Lodestar(payable(factory.rescueDeploy(_params(ELYSP, address(0)), dev)));
        assertEq(source.creator(ELYSP, bytes32(0)), address(elysp));
        assertTrue(elysp.isCreator());
        assertTrue(mix.isCreator(), "MIX's router keeps its own role");
        _volume(source, ELYSP, 0.2 ether, 3);
        assertGt(_owedTo(ELYSP, address(elysp)), 0, "ELYSP's fees now accrue to ELYSP's router");
    }
}
