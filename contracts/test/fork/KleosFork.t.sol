// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {KleosFeeSource} from "../../src/sources/KleosFeeSource.sol";
import {V4FeeSource} from "../../src/sources/V4FeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {IKleosHook} from "../../src/interfaces/ILaunchpadHooks.sol";

interface IKleosCoin {
    function rewardsOf(address holder) external view returns (uint256);
    function claimRewards(address holder) external;
}

/// @notice Lodestar on Kleos (thekleos.xyz) against the real hooks on an Elysium mainnet fork.
contract KleosForkTest is ForkBase {
    address internal constant HOOK_A = 0x0c835e6A51717a514144d95c7F0a1C640179E0Cc;
    address internal constant HOOK_B = 0x772AccB053609D361593345e361D2a6854Ede8cc;
    address internal constant HOOK_C = 0xD5068e7f4e2D70d5eFbaC6fD28A8407252E1EAcC;
    address internal constant PM = 0xb308B5df891c300a5f5a5b8fdBC30108bA842490;

    // hook A, 1% tax, 100% to the creator
    address internal constant AGORA = 0x5e5Df82d563FCF36b6f853c4D09f89e2d18825B4;
    // hook C (multi-quote, HYPE here), 2% tax, 100% to the creator
    address internal constant MANTE = 0x60c9bD4c4245CefF1473b43F9629DC7A9C17E415;
    // hook A, 1.5% tax, 70% creator and 30% holders
    address internal constant BULL = 0xF3bC1443b3aC94FcD77A9808Cc51EbE6007f38bd;
    // hook C, 3% tax, 30% creator and 70% holders, paid to holders in wNVDAx
    address internal constant ECAT = 0x5f471e53Eda2110981b5ac6a1Ee7e7aE5b62B21b;

    KleosFeeSource internal source;
    LodestarFactory internal factory;

    function setUp() public {
        if (!_fork()) return;
        address[] memory hooks = new address[](3);
        uint8[] memory kinds = new uint8[](3);
        (hooks[0], kinds[0]) = (HOOK_A, 1);
        (hooks[1], kinds[1]) = (HOOK_B, 1);
        (hooks[2], kinds[2]) = (HOOK_C, 2);
        source = new KleosFeeSource(observer, address(this), hooks, kinds);
        factory = _factory(IFeeSource(address(source)));
    }

    function _hook(address coin) internal view returns (address hook) {
        (hook,) = source.hookOf(coin);
    }

    function _owedTo(address coin, address who) internal view returns (uint256) {
        (, uint256 q) = source.owed(coin, bytes32(0), who);
        return q;
    }

    /// @dev Kleos is one-step: deploy, then `transferCreator(coin, router)` from the creator.
    function _activate(address coin, address swapper) internal returns (Lodestar l) {
        address dev = source.creator(coin, bytes32(0));
        vm.prank(dev);
        l = Lodestar(payable(factory.deploy(_params(coin, swapper))));
        address hook = _hook(coin);
        vm.prank(dev);
        IKleosHook(hook).transferCreator(coin, address(l));
        assertTrue(l.isCreator(), "router holds the role");
    }

    function test_resolveAndViews() public view {
        (bytes32 id, address hook,) = source.resolve(MANTE, address(0));
        assertEq(hook, HOOK_C);
        assertEq(id, keccak256(abi.encode(IKleosHook(HOOK_C).poolKeyOf(MANTE))));
        assertEq(source.swapCostBps(MANTE, id), 200);
        assertEq(source.swapCostBps(AGORA, bytes32(0)), 100);
        assertEq(source.holdersShareBps(ECAT, bytes32(0)), 7000);
        (address target, bytes4 sel) = source.dividendClaim(BULL);
        assertEq(target, BULL);
        assertEq(sel, bytes4(keccak256("claimRewards(address)")));
        (uint160 spot,, uint128 liq) = source.prices(MANTE, id);
        assertGt(spot, 0);
        assertGt(liq, 0);
    }

    /// @dev Kleos keys creator fees by address: the dev claims what they earned before handing over.
    function _claimAndDistribute(address coin) internal {
        address dev = source.creator(coin, bytes32(0));
        uint256 devOwed = _owedTo(coin, dev);
        Lodestar l = _activate(coin, address(0));
        assertEq(_owedTo(coin, dev), devOwed, "the dev's earlier fees stay the dev's");
        assertEq(_owedTo(coin, address(l)), 0);

        _volume(source, coin, 0.5 ether, 10);
        uint256 owedQ = _owedTo(coin, address(l));
        assertGt(owedQ, 0, "fees accrue to the router");
        l.distribute();
        assertEq(_owedTo(coin, address(l)), 0, "claimCreatorFees paid the router");
        assertEq(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), owedQ);
        assertEq(l.totalHoldersQuote(), owedQ * HOLDERS_BPS / 10_000);
    }

    function test_hookA_claimAndDistribute() public {
        _claimAndDistribute(AGORA);
    }

    function test_hookC_claimAndDistribute() public {
        _claimAndDistribute(MANTE);
    }

    function test_buybackThroughTheRealPool() public {
        Lodestar l = _activate(MANTE, address(_swapper(PM)));
        _volume(source, MANTE, 0.5 ether, 10);
        uint256 deadBefore = IERC20(MANTE).balanceOf(DEAD);
        l.distribute();
        skip(31 minutes);
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0, "bought back on Kleos's pool, net of its buy tax");
        assertEq(IERC20(MANTE).balanceOf(DEAD) - deadBefore, l.totalBuybackTokensBurned());
    }

    function _harvest(address coin) internal {
        Lodestar l = _activate(coin, address(0));
        uint256 poolId = l.exilePoolId();
        (uint256 hPool, address target,) = exile.harvestOf(coin);
        assertEq(hPool, poolId);
        assertEq(target, coin);

        _buy(source, coin, 0.3 ether, locker);
        skip(20 minutes);
        _lock(coin, poolId, IERC20(coin).balanceOf(locker));
        _volume(source, coin, 0.5 ether, 10);
        l.distribute();

        uint256 earned = IKleosCoin(coin).rewardsOf(address(exile));
        assertGt(earned, 0, "Exile earns dividends on locked coins");
        assertEq(exile.harvest(coin), earned, "claimRewards(exile) paid Exile");
        assertEq(IKleosCoin(coin).rewardsOf(address(exile)), 0);

        skip(3 days);
        uint256[] memory ids = exile.lockIdsOf(locker);
        uint256 before = locker.balance;
        vm.prank(locker);
        exile.claimRewards(ids[0]);
        assertApproxEqRel(locker.balance - before, l.totalHoldersQuote() + earned, 1e15);
    }

    function test_harvestOnHookA() public {
        _harvest(BULL);
    }

    /// @dev Hook C pays holders in stock tokens through a separate rewards contract, which Exile can't pass on.
    function test_hookCWithHolderShareIsRefused() public {
        (address target, bytes4 sel) = source.dividendClaim(ECAT);
        assertEq(target, address(0));
        assertEq(sel, bytes4(0));
        address dev = source.creator(ECAT, bytes32(0));
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.HoldersSplitActive.selector);
        factory.deploy(_params(ECAT, address(0)));
    }

    function test_strangerCannotDeploy() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(AGORA, address(0)));
    }

    function test_stewardHandsTheRoleBack() public {
        Lodestar l = _activate(AGORA, address(0));
        address next = makeAddr("next");
        vm.prank(l.steward());
        l.transferCreatorOut(next);
        assertEq(source.creator(AGORA, bytes32(0)), next);
        assertFalse(l.isCreator());
    }
}
