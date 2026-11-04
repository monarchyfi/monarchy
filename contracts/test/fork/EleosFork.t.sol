// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {EleosFeeSource} from "../../src/sources/EleosFeeSource.sol";
import {V4FeeSource} from "../../src/sources/V4FeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {IEleosHook} from "../../src/interfaces/ILaunchpadHooks.sol";

interface IEleosCoin {
    function claimFor(address holder) external returns (uint256);
    function claimable(address holder) external view returns (uint256);
}

/// @notice Lodestar on Eleos (eleos.fun) against the real hooks on an Elysium mainnet fork.
contract EleosForkTest is ForkBase {
    address internal constant HOOK1 = 0x6BcDf22D303C029805a733270E450C99E1DbAACC;
    address internal constant HOOK2 = 0xb0dcb98508173C29AD57Df444EE3e91fc681aacc;
    address internal constant HOOK3 = 0x8680965555DCEa2a4c0Ed3a29e59a8AA424E6acC;
    address internal constant PM = 0x5c54A7293D96B11a29A0256eE8dfdBC3059637Da;

    // 100% of the creator split to the creator
    address internal constant ELYSA = 0x1A54F9C9e97372060943E85525d70d9080671bF7;
    address internal constant SLYMZ = 0xE7c0872e251b4aF2322FA71F7826dA5bB7d079D7;
    // 50% creator, 30% holders, 20% buyback: pays its holders HYPE dividends inside the coin
    address internal constant TST2255 = 0x1EaDE08E6BEf1ac50bac8A70e230A26286be3a85;
    // a Kleos coin, whose hook Eleos's adapter doesn't know
    address internal constant AGORA = 0x5e5Df82d563FCF36b6f853c4D09f89e2d18825B4;

    EleosFeeSource internal source;
    LodestarFactory internal factory;

    function setUp() public {
        if (!_fork()) return;
        address[] memory hooks = new address[](3);
        hooks[0] = HOOK1;
        hooks[1] = HOOK2;
        hooks[2] = HOOK3;
        uint8[] memory kinds = new uint8[](3);
        kinds[0] = kinds[1] = kinds[2] = 1;
        source = new EleosFeeSource(observer, address(this), hooks, kinds);
        factory = _factory(IFeeSource(address(source)));
    }

    function _creator(address coin) internal view returns (address) {
        return IEleosHook(HOOK3).config(coin).creator;
    }

    /// @dev Eleos is one-step: deploy first, then the creator hands the role to the router.
    function _activate(address coin, address swapper) internal returns (Lodestar l) {
        address dev = _creator(coin);
        vm.prank(dev);
        l = Lodestar(payable(factory.deploy(_params(coin, swapper))));
        assertFalse(l.isCreator(), "role not moved yet");
        vm.prank(dev);
        IEleosHook(HOOK3).transferCreator(coin, address(l));
        assertTrue(l.isCreator(), "router holds the role");
        assertEq(IEleosHook(HOOK3).config(coin).creator, address(l));
    }

    function test_resolveAndViews() public {
        (bytes32 id, address hook, bool tokenIs0) = source.resolve(ELYSA, address(0));
        assertEq(hook, HOOK3);
        assertFalse(tokenIs0);
        assertEq(id, IEleosHook(HOOK3).poolIdOf(ELYSA));
        assertEq(source.creator(ELYSA, id), _creator(ELYSA));
        assertEq(source.holdersShareBps(TST2255, bytes32(0)), 3000);
        assertEq(source.swapCostBps(ELYSA, id), 300);
        (uint160 spot,, uint128 liq) = source.prices(ELYSA, id);
        assertGt(spot, 0);
        assertGt(liq, 0);
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(ELYSA, address(0xBEEF));
        vm.expectRevert(V4FeeSource.UnsupportedHook.selector);
        source.resolve(AGORA, address(0));
    }

    function test_activateClaimAndDistribute() public {
        Lodestar l = _activate(ELYSA, address(0));
        uint256 poolId = l.exilePoolId();

        // a locker joins before fees flow
        _buy(source, ELYSA, 0.3 ether, locker);
        skip(20 minutes);
        _lock(ELYSA, poolId, IERC20(ELYSA).balanceOf(locker));

        _volume(source, ELYSA, 0.2 ether, 10);
        (, uint256 owedQ) = source.owed(ELYSA, l.poolId(), address(l));
        assertGt(owedQ, 0, "tax owed to the router");

        l.distribute();
        // process + payCreator moved the creator share to the router, which split it at once
        uint256 routed = l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve();
        assertApproxEqAbs(routed, owedQ, 2, "everything owed was routed");
        assertEq(l.totalHoldersQuote(), owedQ * HOLDERS_BPS / 10_000, "50% to lockers");
        assertEq(address(l).balance, l.buybackReserve(), "only the buyback share waits, no swapper yet");
        assertEq(IEleosHook(HOOK3).book(ELYSA).creatorOwed, 0);

        skip(3 days);
        uint256[] memory ids = exile.lockIdsOf(locker);
        uint256 before = locker.balance;
        vm.prank(locker);
        exile.claimRewards(ids[0]);
        assertApproxEqRel(
            locker.balance - before, l.totalHoldersQuote(), 1e15, "the only locker earns the lot"
        );
        assertGt(_streamClaimable(l), 0, "treasury stream vests");
    }

    function test_buybackThroughTheRealPool() public {
        Lodestar l = _activate(SLYMZ, address(_swapper(PM)));
        _volume(source, SLYMZ, 0.2 ether, 10);
        l.distribute(); // first poke starts the observer; no average yet, so the buyback waits
        assertGt(l.buybackReserve(), 0);
        assertEq(l.totalBuybackTokensBurned(), 0);

        // the observer's 30 minute average needs a full window of watching before any buyback
        skip(31 minutes);
        uint256 deadBefore = IERC20(SLYMZ).balanceOf(DEAD);
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0, "bought back on Eleos's pool");
        assertEq(IERC20(SLYMZ).balanceOf(DEAD) - deadBefore, l.totalBuybackTokensBurned());
    }

    function test_harvestPaysLockersTheCoinsDividends() public {
        Lodestar l = _activate(TST2255, address(0));
        uint256 poolId = l.exilePoolId();
        (uint256 hPool, address target, bytes4 sel) = exile.harvestOf(TST2255);
        assertEq(hPool, poolId);
        assertEq(target, TST2255);
        assertEq(sel, bytes4(keccak256("claimFor(address)")));

        _buy(source, TST2255, 0.3 ether, locker);
        skip(20 minutes);
        _lock(TST2255, poolId, IERC20(TST2255).balanceOf(locker));
        _volume(source, TST2255, 0.2 ether, 10);
        l.distribute(); // process pays the holders' 30% into the coin, where Exile's balance earns its part

        uint256 earned = IEleosCoin(TST2255).claimable(address(exile));
        assertGt(earned, 0, "Exile earns dividends on locked coins");
        uint256 got = exile.harvest(TST2255);
        assertEq(got, earned);
        assertEq(IEleosCoin(TST2255).claimable(address(exile)), 0);

        // a third party pushing Exile's dividends is counted for the coin and joins the next harvest
        _volume(source, TST2255, 0.2 ether, 6);
        l.distribute();
        uint256 pushed = IEleosCoin(TST2255).claimable(address(exile));
        assertGt(pushed, 0);
        IEleosCoin(TST2255).claimFor(address(exile));
        assertEq(exile.unattributed(TST2255), pushed);
        assertEq(exile.harvest(TST2255), pushed);
        assertEq(exile.unattributed(TST2255), 0);

        skip(3 days);
        uint256[] memory ids = exile.lockIdsOf(locker);
        uint256 before = locker.balance;
        vm.prank(locker);
        exile.claimRewards(ids[0]);
        assertApproxEqRel(
            locker.balance - before,
            l.totalHoldersQuote() + got + pushed,
            1e15,
            "fees plus harvested dividends"
        );
    }

    function test_strangerCannotDeploy() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(ELYSA, address(0)));
    }

    /// @dev Handing the role over before deploying strands it; only the factory owner can finish the deploy.
    function test_roleSentFirstNeedsRescue() public {
        (address predicted,) = factory.predict(ELYSA, address(0));
        address dev = _creator(ELYSA);
        vm.prank(dev);
        IEleosHook(HOOK3).transferCreator(ELYSA, predicted);
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(ELYSA, address(0)));

        Lodestar l = Lodestar(payable(factory.rescueDeploy(_params(ELYSA, address(0)), dev)));
        assertEq(address(l), predicted);
        assertTrue(l.isCreator());
        assertEq(l.steward(), dev);
    }

    function test_stewardHandsTheRoleBack() public {
        Lodestar l = _activate(ELYSA, address(0));
        address dev = _creator(ELYSA) == address(l) ? l.steward() : address(0);
        address next = makeAddr("next");
        vm.prank(dev);
        l.transferCreatorOut(next);
        assertEq(IEleosHook(HOOK3).config(ELYSA).creator, next);
        assertFalse(l.isCreator());
    }
}
