// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Exile} from "../../src/Exile.sol";
import {IExile} from "../../src/interfaces/IExile.sol";
import {Sandfall} from "../../src/Sandfall.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {AscendSwapper} from "../../src/AscendSwapper.sol";
import {ILodestar} from "../../src/interfaces/ILodestar.sol";
import {ISandfall} from "../../src/interfaces/ISandfall.sol";
import {IAscendLaunchpad} from "../../src/interfaces/IAscendLaunchpad.sol";
import {IListingDesk} from "../../src/interfaces/IListingDesk.sol";
import {ICLPoolManager, IVault} from "../../src/interfaces/IInfinity.sol";
import {MonarchTiers} from "../../src/libraries/MonarchTiers.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockAscendPool} from "../../src/mocks/MockAscendPool.sol";
import {MockAscendLaunchpad} from "../../src/mocks/MockAscendLaunchpad.sol";
import {MockListingDesk} from "../../src/mocks/MockListingDesk.sol";
import {AscendFeeSource} from "../../src/sources/AscendFeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";

/// @notice Full mock Ascend plus Monarchy core, shared by the Lodestar, swapper and integration tests.
abstract contract MonarchyFixture is Test {
    uint256 internal constant T0 = 1_700_000_000 - (1_700_000_000 % 3600);
    uint256 internal constant TOKEN_SEED = 800_000_000e18;
    uint256 internal constant QUOTE_SEED = 50_000e6;
    address internal constant DEAD = 0xdEAD000000000000000042069420694206942069;

    MockAscendPool internal pool;
    MockAscendLaunchpad internal launchpad;
    MockListingDesk internal desk;
    MockERC20 internal usdc;
    Exile internal exile;
    Sandfall internal sandfall;
    Lodestar internal impl;
    LodestarFactory internal factory;
    AscendSwapper internal swapper;
    AscendFeeSource internal ascendSource;

    address internal dev = makeAddr("dev");
    address internal treasury = makeAddr("treasury");
    address internal trader = makeAddr("trader");

    function _deployCore(address quoteAt) internal {
        vm.warp(T0);
        pool = new MockAscendPool();
        launchpad = new MockAscendLaunchpad(pool);
        desk = new MockListingDesk(launchpad);
        if (quoteAt == address(0)) {
            usdc = new MockERC20("Mock USDC", "USDC", 6);
        } else {
            deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Mock USDC", "USDC", uint8(6)), quoteAt);
            usdc = MockERC20(quoteAt);
        }
        exile = new Exile();
        sandfall = new Sandfall();
        impl = new Lodestar();
        swapper = new AscendSwapper(
            IVault(address(pool)), ICLPoolManager(address(pool)), IAscendLaunchpad(address(launchpad))
        );
        ascendSource = new AscendFeeSource(
            IAscendLaunchpad(address(launchpad)), IListingDesk(address(desk)), ICLPoolManager(address(pool))
        );
        factory = new LodestarFactory(
            address(impl),
            IFeeSource(address(ascendSource)),
            exile,
            ISandfall(address(sandfall)),
            address(swapper),
            address(this)
        );
    }

    function _launch(string memory symbol) internal returns (MockERC20 token, bytes32 poolId) {
        usdc.mint(address(this), QUOTE_SEED);
        usdc.approve(address(launchpad), QUOTE_SEED);
        address t;
        (t, poolId) = launchpad.launch(symbol, symbol, address(usdc), dev, TOKEN_SEED, QUOTE_SEED);
        token = MockERC20(t);
    }

    function _params(MockERC20 token, uint16 burn, uint16 holders, uint16 treas, address swapper_, bool listing)
        internal
        view
        returns (LodestarFactory.DeployParams memory p)
    {
        p.token = address(token);
        p.quote = address(usdc);
        p.cfg = ILodestar.Config({
            burnBps: burn, holdersBps: holders, treasuryBps: treas, swapper: swapper_, maxSlippageBps: 300,
            tokenToHolders: false
        });
        p.treasuryRecipient = treasury;
        p.treasuryWindow = 30 days;
        p.tiers = MonarchTiers.defaults();
        p.enrolListing = listing;
        p.listingCap = 5_000e6;
    }

    /// @dev The two-step activation a dev does after launching on Ascend's site.
    function _activate(LodestarFactory.DeployParams memory p) internal returns (Lodestar l) {
        (address predicted, bytes32 poolId) = factory.predict(p.token, p.quote);
        vm.prank(dev);
        launchpad.transferCreator(poolId, predicted);
        vm.prank(dev);
        l = Lodestar(payable(factory.deploy{gas: 5_000_000}(p)));
    }

    function _buy(bytes32 poolId, address who, uint256 quoteIn) internal returns (uint256 out) {
        usdc.mint(who, quoteIn);
        vm.startPrank(who);
        usdc.approve(address(swapper), quoteIn);
        out = swapper.buyExactIn(poolId, quoteIn, 0, who);
        vm.stopPrank();
    }

    function _sell(bytes32 poolId, MockERC20 token, address who, uint256 tokenIn) internal returns (uint256 out) {
        vm.startPrank(who);
        token.approve(address(swapper), tokenIn);
        out = swapper.sellExactIn(poolId, tokenIn, 0, who);
        vm.stopPrank();
    }
}
