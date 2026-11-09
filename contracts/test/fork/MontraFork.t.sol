// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {MontraFeeSource} from "../../src/sources/MontraFeeSource.sol";
import {V4FeeSource} from "../../src/sources/V4FeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {IMontraHook, IMontraToken} from "../../src/interfaces/ILaunchpadHooks.sol";

/// @notice Lodestar on Montra (montramarkets.xyz) against its real launch hook on an Elysium mainnet fork.
contract MontraForkTest is ForkBase {
    address internal constant HOOK = 0x6b1216A40B65c83e9c9e18a562C446697B8cf8EC; // the launch hook
    address internal constant POOL_MANAGER = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1; // the official one

    // 1% tier, paid to its creator's wallet, past graduation
    address internal constant ELYSA = 0xCaC5B6e74eB7383AF0a6DC344D996e225BBF9a17;
    // 2% tier, paid to its creator's wallet, before graduation
    address internal constant UMBRA = 0xD11345b5953100b70D4B2a93D33D8cb8D41e0e8F;
    // 3% tier, paid to another wallet than its launcher's
    address internal constant FULC = 0xad330616F1E0033dE331B3C95abBe193A01C3554;
    // 10% tier
    address internal constant ROCCO = 0xBc68177E2d0301730C9b4103B6f08C81c1e27BCB;
    // paid to its holders: can never change recipient
    address internal constant EACCAT = 0x32193Afd14c53f12c45A4c04ECA9F7Ba98e3ec71;
    // paid to a splitter
    address internal constant NECTAR = 0x911f19c1C39596F158ED5C314548d0FCf382003E;
    // an ElysPump coin: not Montra's hook
    address internal constant ELYSP = 0x7a7AE0e715867fc3b0055192624982017328c60B;

    MontraFeeSource internal source;
    LodestarFactory internal factory;

    function setUp() public {
        if (!_fork()) return;
        address[] memory hooks = new address[](1);
        uint8[] memory kinds = new uint8[](1);
        (hooks[0], kinds[0]) = (HOOK, 1);
        source = new MontraFeeSource(observer, address(this), hooks, kinds);
        factory = _factory(IFeeSource(address(source)));
    }

    function _id(address coin) internal view returns (bytes32) {
        return IMontraToken(coin).poolId();
    }

    function _owedTo(address coin, address who) internal view returns (uint256 q) {
        (, q) = source.owed(coin, bytes32(0), who);
    }

    /// @dev Montra is one-step: deploy, then `updateRecipient(poolId, router)` from the recipient. `claimFirst`
    /// has the dev take their own fees before handing over.
    function _activate(address coin, address swapper, bool claimFirst) internal returns (Lodestar l) {
        address dev = source.creator(coin, bytes32(0));
        bytes32 id = _id(coin); // read before a prank, which the next external call takes
        vm.prank(dev);
        l = Lodestar(payable(factory.deploy(_params(coin, swapper))));
        if (claimFirst) {
            vm.prank(dev);
            IMontraHook(HOOK).claim(id, dev);
        }
        vm.prank(dev);
        IMontraHook(HOOK).updateRecipient(id, address(l));
        assertTrue(l.isCreator(), "router holds the role");
    }

    function test_registryAndViews() public view {
        (uint8 kind, address pm) = source.hooks(HOOK);
        assertEq(kind, 1);
        assertEq(pm, POOL_MANAGER);
        (bytes32 id, address hook, bool tokenIs0) = source.resolve(ELYSA, address(0));
        assertEq(hook, HOOK);
        assertFalse(tokenIs0);
        assertEq(id, _id(ELYSA));
        assertEq(keccak256(abi.encode(IMontraHook(HOOK).poolKey(id))), id);
        assertEq(source.payer(ELYSA), address(0), "the hook pays its own fees");
        assertEq(source.creator(ELYSA, id), IMontraHook(HOOK).recipientOf(id));
        assertEq(source.swapCostBps(ELYSA, id), 100);
        assertEq(source.swapCostBps(UMBRA, bytes32(0)), 200);
        assertEq(source.swapCostBps(ROCCO, bytes32(0)), 1000);
        assertEq(source.holdersShareBps(ELYSA, id), 0);
        (address target, bytes4 sel) = source.dividendClaim(ELYSA);
        assertEq(target, address(0));
        assertEq(sel, bytes4(0));
        assertEq(source.burnSink(ELYSA), DEAD);
        assertTrue(source.handover() == IFeeSource.Handover.OneStep);
        (uint160 spot,, uint128 liq) = source.prices(ELYSA, id);
        assertGt(spot, 0);
        assertGt(liq, 0);
    }

    function test_refusesWhatItCantRoute() public {
        vm.expectRevert(MontraFeeSource.FeesGoToHolders.selector);
        source.resolve(EACCAT, address(0));
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(ELYSA, makeAddr("someQuote"));
        vm.expectRevert(V4FeeSource.UnsupportedHook.selector);
        source.resolve(ELYSP, address(0));
        // a splitter is the recipient: only it could activate, and it can't call the factory
        address splitter = source.creator(NECTAR, bytes32(0));
        assertGt(splitter.code.length, 0);
        vm.prank(makeAddr("launcher"));
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(NECTAR, address(0)));
    }

    /// @dev A token that names Montra's hook and a real pool, without being that pool's coin, borrows nothing.
    function test_refusesALookalike() public {
        LookalikeMontraToken fake = new LookalikeMontraToken(HOOK, _id(ELYSA));
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(address(fake), address(0));
    }

    /// @dev Montra keeps fees by pool: the dev claims first, or the router routes what was unclaimed.
    function test_claimFirstThenDistribute() public {
        address dev = source.creator(ELYSA, bytes32(0));
        uint256 devOwed = _owedTo(ELYSA, dev);
        assertGt(devOwed, 0, "the dev has fees waiting");
        uint256 before = dev.balance;
        Lodestar l = _activate(ELYSA, address(0), true);
        assertGe(dev.balance - before, devOwed, "the dev's claim paid the dev");
        assertEq(_owedTo(ELYSA, address(l)), 0);
        assertEq(_owedTo(ELYSA, dev), 0, "a former recipient is owed nothing");

        _volume(source, ELYSA, 0.5 ether, 10);
        uint256 owedQ = _owedTo(ELYSA, address(l));
        // 5 HYPE of buys at 1%: 0.4% to Montra, the rest to the creator side (no LP fee before the LP line)
        assertApproxEqRel(owedQ, 0.03 ether, 0.02e18);
        l.distribute();
        assertEq(_owedTo(ELYSA, address(l)), 0, "claim paid the router");
        uint256 routed = l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve();
        assertGe(routed, owedQ, "the claim also takes the seed's LP fees");
        assertApproxEqRel(routed, owedQ, 0.05e18);
    }

    function test_unclaimedFeesGoWithTheRole() public {
        address dev = source.creator(UMBRA, bytes32(0));
        uint256 devOwed = _owedTo(UMBRA, dev);
        Lodestar l = _activate(UMBRA, address(0), false);
        assertEq(_owedTo(UMBRA, address(l)), devOwed, "what the dev left unclaimed is the router's now");
        l.distribute();
        assertGe(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), devOwed);
    }

    function test_anotherWalletActivates() public {
        Lodestar l = _activate(FULC, address(0), true);
        _volume(source, FULC, 0.5 ether, 4);
        assertGt(_owedTo(FULC, address(l)), 0);
        l.distribute();
        assertGt(l.totalHoldersQuote(), 0);
    }

    function test_buybackThroughMontrasPool() public {
        Lodestar l = _activate(ELYSA, address(_swapper(POOL_MANAGER)), true);
        _volume(source, ELYSA, 0.5 ether, 10);
        uint256 deadBefore = IERC20(ELYSA).balanceOf(DEAD);
        l.distribute();
        skip(31 minutes);
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0, "bought back on Montra's pool, net of its fee");
        assertEq(IERC20(ELYSA).balanceOf(DEAD) - deadBefore, l.totalBuybackTokensBurned());
    }

    function test_noHarvestForExile() public {
        _activate(ELYSA, address(0), true);
        (, address target, bytes4 sel) = exile.harvestOf(ELYSA);
        assertEq(target, address(0));
        assertEq(sel, bytes4(0));
    }

    function test_strangerCannotDeploy() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(ELYSA, address(0)));
    }

    function test_onlyTheRecipientMovesTheRole() public {
        bytes32 id = _id(ELYSA);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        IMontraHook(HOOK).updateRecipient(id, makeAddr("stranger"));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        IMontraHook(HOOK).claim(id, makeAddr("stranger"));
    }

    function test_stewardHandsTheRoleBack() public {
        Lodestar l = _activate(ELYSA, address(0), true);
        address next = makeAddr("next");
        vm.prank(l.steward());
        l.transferCreatorOut(next);
        assertEq(source.creator(ELYSA, bytes32(0)), next);
        assertFalse(l.isCreator());
    }

    /// @dev UMBRA's creator names ELYSA's router as UMBRA's recipient. Montra keeps fees by pool, so ELYSA's router
    /// could never claim UMBRA's (its adapter only claims ELYSA's pool); the owner moves the role into UMBRA's own
    /// router.
    function test_roleSentToAnotherCoinsRouterIsRescued() public {
        Lodestar elysa = _activate(ELYSA, address(0), true);
        address dev = source.creator(UMBRA, bytes32(0));
        bytes32 id = _id(UMBRA);
        vm.prank(dev);
        IMontraHook(HOOK).updateRecipient(id, address(elysa));
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(UMBRA, address(0)));

        Lodestar umbra = Lodestar(payable(factory.rescueDeploy(_params(UMBRA, address(0)), dev)));
        assertEq(source.creator(UMBRA, bytes32(0)), address(umbra));
        assertTrue(umbra.isCreator());
        assertTrue(elysa.isCreator(), "ELYSA's router keeps its own role");
    }
}

/// @dev Names Montra's hook and someone else's pool, like a Montra coin.
contract LookalikeMontraToken {
    address public immutable hook;
    bytes32 public immutable poolId;

    constructor(address hook_, bytes32 poolId_) {
        hook = hook_;
        poolId = poolId_;
    }
}
