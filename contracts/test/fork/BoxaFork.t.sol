// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {BoxaFeeSource} from "../../src/sources/BoxaFeeSource.sol";
import {V4FeeSource} from "../../src/sources/V4FeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {IBoxaHook} from "../../src/interfaces/ILaunchpadHooks.sol";

interface IBoxaCoin {
    function rewardsOf(address holder) external view returns (uint256);
}

interface IBoxaRelease {
    function releaseHolderRewards(bytes32 poolId) external;
}

/// @notice Lodestar on Boxa (boxa.club) against the real hooks on an Elysium mainnet fork.
contract BoxaForkTest is ForkBase {
    address internal constant MAIN = 0xBCc1f22d137C1D98DFa5548E4d4261D7AeE06acC;
    address internal constant PAIRS = 0xB3E25CDf4a2f42e7f37aB3aE43Bfb90EE8052AcC;
    address internal constant MEME = 0xD2f8e16ba85e9D160724e893B3ebCe53D00E6Acc;
    address internal constant UNI = 0x00C002Cdae688F39a90CF2AD74c59421C9502aCC;
    address internal constant PM = 0x06C63714fBf1F5753017123E2FcfdEde4540B2c4;
    address internal constant UNI_PM = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1;

    // main hook: 100% creator, 2% fee
    address internal constant BOXA = 0xa3C1d6a8648dF3978A38ce1478fbC284c75D95D7;
    // main hook: 30% creator, 20% buyback, 50% holders
    address internal constant EPEPE = 0x21F9e36407B098A99A6727837077bBd0FF1A06CD;
    // pairs hook, HYPE-quoted: 5% creator, 20% buyback, 75% holders
    address internal constant CHUD = 0xee522C896A72dbE25Ca02d6a56C9E0E41D9FD27E;
    // pairs hook, HYPE-quoted: 100% creator
    address internal constant ELYCHAD = 0x0B6165b8877eD7232121a914686Bb9037DE3006e;
    // uni hook on its own pool manager: 100% creator, 1% buy fee
    address internal constant SPHERE = 0x68D2568D4B4a84CC631471eE63f5AD8505fB71EE;
    // uni hook: 85% creator, 5% buyback, 10% holders, 5% buy fee
    address internal constant ELYSPAD = 0x75fd3A84395a642597447126846Ae00D58F10D57;
    // meme-pairs hook quoted in another Boxa coin, and a pairs coin quoted in KNTQ
    address internal constant HELYCAT = 0xA623D1B33E4F80fF8D3F4217552cC55dd1434EDf;
    address internal constant KNTQU = 0xE7A130ceA4E58d068897A26f0622024F138cF3Cf;

    BoxaFeeSource internal source;
    LodestarFactory internal factory;

    function setUp() public {
        if (!_fork()) return;
        address[] memory hooks = new address[](4);
        uint8[] memory kinds = new uint8[](4);
        (hooks[0], kinds[0]) = (MAIN, 1);
        (hooks[1], kinds[1]) = (PAIRS, 2);
        (hooks[2], kinds[2]) = (MEME, 2);
        (hooks[3], kinds[3]) = (UNI, 3);
        source = new BoxaFeeSource(observer, address(this), hooks, kinds);
        factory = _factory(IFeeSource(address(source)));
    }

    function _id(address coin) internal view returns (bytes32) {
        (address hook,) = source.hookOf(coin);
        return IBoxaHook(hook).poolOf(coin);
    }

    /// @dev Boxa is two-step, like Ascend: propose the predicted router, then deploy (which accepts).
    function _activate(address coin, address swapper) internal returns (Lodestar l) {
        bytes32 id = _id(coin);
        (address hook,) = source.hookOf(coin);
        address dev = source.creator(coin, id);
        (address predicted,) = factory.predict(coin, address(0));
        vm.prank(dev);
        IBoxaHook(hook).proposeCreator(id, predicted);
        assertEq(source.pendingCreator(coin, id), predicted);
        vm.prank(dev);
        l = Lodestar(payable(factory.deploy(_params(coin, swapper))));
        assertEq(address(l), predicted);
        assertTrue(l.isCreator(), "router accepted the role");
        assertEq(source.pendingCreator(coin, id), address(0));
    }

    function test_resolveAndViews() public view {
        (bytes32 id, address hook,) = source.resolve(BOXA, address(0));
        assertEq(hook, MAIN);
        assertEq(id, IBoxaHook(MAIN).poolOf(BOXA));
        assertEq(source.creator(BOXA, id), 0x0401Cdad63FF4cC794C745aE48BC6a551A545426);
        assertEq(source.swapCostBps(BOXA, id), 200);
        assertEq(source.holdersShareBps(EPEPE, _id(EPEPE)), 5000);
        assertEq(source.holdersShareBps(CHUD, _id(CHUD)), 7500);
        assertEq(source.swapCostBps(SPHERE, _id(SPHERE)), 100);
        (, V4FeeSource.HookInfo memory info) = source.hookOf(SPHERE);
        assertEq(info.poolManager, UNI_PM);
        (uint160 spot,, uint128 liq) = source.prices(SPHERE, _id(SPHERE));
        assertGt(spot, 0);
        assertGt(liq, 0);
        (address target, bytes4 sel) = source.dividendClaim(CHUD);
        assertEq(target, PAIRS);
        assertEq(sel, bytes4(keccak256("claimRewards(address,address)")));
    }

    function test_quotedInAnotherTokenIsRefused() public {
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(HELYCAT, address(0));
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(KNTQU, address(0));
    }

    function test_proposalRequiredFirst() public {
        address dev = source.creator(BOXA, _id(BOXA));
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.TransferCreatorFirst.selector);
        factory.deploy(_params(BOXA, address(0)));
    }

    /// @dev Boxa keys creator fees by address: what the dev earned before the handover stays theirs.
    function test_mainHookClaimAndDistribute() public {
        address dev = source.creator(BOXA, _id(BOXA));
        uint256 devOwed = IBoxaHook(MAIN).claimable(dev);
        Lodestar l = _activate(BOXA, address(0));
        assertEq(IBoxaHook(MAIN).claimable(dev), devOwed, "the dev's earlier fees stay the dev's");
        uint256 poolId = l.exilePoolId();
        _buy(source, BOXA, 0.5 ether, locker);
        skip(20 minutes);
        _lock(BOXA, poolId, IERC20(BOXA).balanceOf(locker));

        _volume(source, BOXA, 1 ether, 10);
        (, uint256 owedQ) = source.owed(BOXA, l.poolId(), address(l));
        assertGt(owedQ, 0);
        l.distribute();
        assertEq(IBoxaHook(MAIN).claimable(address(l)), 0, "claim(router) paid the router");
        assertEq(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), owedQ);
        assertEq(l.totalHoldersQuote(), owedQ * HOLDERS_BPS / 10_000);

        skip(3 days);
        uint256[] memory ids = exile.lockIdsOf(locker);
        uint256 before = locker.balance;
        vm.prank(locker);
        exile.claimRewards(ids[0]);
        assertApproxEqRel(locker.balance - before, l.totalHoldersQuote(), 1e15);
    }

    /// @dev The pairs hook's `claim(pair, recipient)`: HYPE is pair 0, paid to the router.
    function test_pairsHookClaimOrder() public {
        Lodestar l = _activate(ELYCHAD, address(0));
        _volume(source, ELYCHAD, 0.5 ether, 6);
        uint256 owedQ = IBoxaHook(PAIRS).claimable(address(0), address(l));
        assertGt(owedQ, 0);
        l.distribute();
        assertEq(IBoxaHook(PAIRS).claimable(address(0), address(l)), 0);
        assertEq(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), owedQ);
    }

    /// @dev The uni hook on its own pool manager: `claimable(payee, currency)`, `claim(currency, recipient)`.
    function test_uniHookClaimOrder() public {
        Lodestar l = _activate(SPHERE, address(0));
        _volume(source, SPHERE, 0.5 ether, 6);
        uint256 owedQ = IBoxaHook(UNI).claimable(address(l), address(0));
        assertGt(owedQ, 0);
        l.distribute();
        assertEq(IBoxaHook(UNI).claimable(address(l), address(0)), 0);
        assertEq(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), owedQ);
    }

    function test_buybackThroughTheRealPool() public {
        Lodestar l = _activate(BOXA, address(_swapper(PM)));
        // the buys poke the observer, so by the end of this its 30 minute average is live
        _volume(source, BOXA, 1 ether, 10);
        uint256 deadBefore = IERC20(BOXA).balanceOf(DEAD);
        l.distribute();
        skip(31 minutes);
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0, "bought back on Boxa's pool, net of its 2% fee");
        assertEq(IERC20(BOXA).balanceOf(DEAD) - deadBefore, l.totalBuybackTokensBurned());
    }

    function test_buybackOnTheUniPoolManager() public {
        Lodestar l = _activate(SPHERE, address(_swapper(UNI_PM)));
        _volume(source, SPHERE, 0.5 ether, 10);
        l.distribute();
        skip(31 minutes);
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0);
    }

    function _harvest(address coin, address hook) internal {
        Lodestar l = _activate(coin, address(0));
        uint256 poolId = l.exilePoolId();
        (uint256 hPool, address target, bytes4 sel) = exile.harvestOf(coin);
        assertEq(hPool, poolId);
        assertEq(target, hook);
        assertEq(sel, bytes4(keccak256("claimRewards(address,address)")));

        _buy(source, coin, 0.5 ether, locker);
        skip(20 minutes);
        _lock(coin, poolId, IERC20(coin).balanceOf(locker));
        _volume(source, coin, 0.5 ether, 10);
        IBoxaRelease(hook).releaseHolderRewards(_id(coin));
        uint256 earned = IBoxaCoin(coin).rewardsOf(address(exile));
        assertGt(earned, 0, "Exile earns dividends on locked coins");
        assertEq(exile.harvest(coin), earned, "hook.claimRewards(coin, exile) paid Exile");
        assertEq(IBoxaCoin(coin).rewardsOf(address(exile)), 0);

        l.distribute();
        skip(3 days);
        uint256[] memory ids = exile.lockIdsOf(locker);
        uint256 before = locker.balance;
        vm.prank(locker);
        exile.claimRewards(ids[0]);
        assertApproxEqRel(locker.balance - before, l.totalHoldersQuote() + earned, 1e15);
    }

    function test_harvestOnTheMainHook() public {
        _harvest(EPEPE, MAIN);
    }

    function test_harvestOnThePairsHook() public {
        _harvest(CHUD, PAIRS);
    }

    function test_harvestOnTheUniHook() public {
        _harvest(ELYSPAD, UNI);
    }

    function test_stewardProposesAndCancels() public {
        Lodestar l = _activate(BOXA, address(0));
        address next = makeAddr("next");
        vm.startPrank(l.steward());
        l.transferCreatorOut(next);
        assertEq(source.pendingCreator(BOXA, _id(BOXA)), next);
        l.transferCreatorOut(address(0));
        assertEq(source.pendingCreator(BOXA, _id(BOXA)), address(0), "proposeCreator(id, 0) cancels");
        vm.stopPrank();
        assertTrue(l.isCreator());
    }
}
