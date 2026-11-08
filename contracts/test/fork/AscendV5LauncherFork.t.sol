// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {AscendV5Swapper} from "../../src/AscendV5Swapper.sol";
import {AscendV5Launcher} from "../../src/AscendV5Launcher.sol";
import {AscendV5FeeSource} from "../../src/sources/AscendV5FeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {
    IAscendV5Launchpad,
    IAscendV5Escrow,
    IAscendV5EscrowFactory
} from "../../src/interfaces/IAscendV5.sol";

interface IWHYPEL {
    function deposit() external payable;
}

/// @notice Launching through Monarchy on Ascend v5: real coins launched on an Elysium mainnet fork with their router
/// as fee owner from the first trade, no 48 hour hand-off.
contract AscendV5LauncherForkTest is ForkBase {
    address internal constant LAUNCHPAD = 0xe0dEF4221b9840a610D4e7d55812a79A6431a8eC;
    address internal constant ESCROW_FACTORY = 0x63f6a8A8d0257c0363251a50cdE8A8b1046e4d19;
    address internal constant BURN_SINK = 0x9F0b0e3B362937b07Cd1E869b50687961e0c7741;
    address internal constant WHYPE = 0xbA876237B0F021A6c6D852d6c26E107997cC5E81;
    address internal constant USDC = 0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65;
    // a live Vanilla coin whose escrow pays a wallet
    address internal constant COIN_3 = 0x086f8850FBC3101c4Bdc6932c3D5f639cb34D2DF;

    AscendV5FeeSource internal source;
    AscendV5Swapper internal v5swapper;
    LodestarFactory internal factory;
    AscendV5Launcher internal launcher;
    address internal creator = makeAddr("creator");

    function setUp() public {
        if (!_fork()) return;
        source = new AscendV5FeeSource(IAscendV5Launchpad(LAUNCHPAD), BURN_SINK);
        v5swapper = new AscendV5Swapper(IAscendV5Launchpad(LAUNCHPAD));
        factory = _factory(IFeeSource(address(source)));
        launcher = new AscendV5Launcher(factory, WHYPE);
        factory.setLauncher(address(launcher));

        vm.deal(creator, 100 ether);
        vm.startPrank(creator);
        IWHYPEL(WHYPE).deposit{value: 50 ether}();
        IERC20(WHYPE).approve(address(launcher), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(trader);
        IWHYPEL(WHYPE).deposit{value: 5_000 ether}();
        IERC20(WHYPE).approve(address(v5swapper), type(uint256).max);
        vm.stopPrank();
    }

    function _coin(uint24 fee, uint256 devBuy) internal pure returns (AscendV5Launcher.Coin memory c) {
        c = AscendV5Launcher.Coin({
            name: "Monarchy Rehearsal",
            symbol: "MRH",
            quote: WHYPE,
            fee: fee,
            devBuyQuote: devBuy,
            minDevOut: 0,
            salt: keccak256("one")
        });
    }

    function _profile() internal pure returns (AscendV5Launcher.Profile memory p) {
        p.image = "ipfs://bafkreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy";
        p.description = "A coin whose fees run through Monarchy from the first trade.";
        p.website = "https://example.com";
    }

    function _deployParams(address token, address quote)
        internal
        view
        returns (LodestarFactory.DeployParams memory d)
    {
        d = _params(token, address(v5swapper));
        d.quote = quote;
    }

    function _launch(AscendV5Launcher.Coin memory c, uint64 lockUntil, string memory plan)
        internal
        returns (address token, bytes32 poolId, Lodestar l)
    {
        (address predicted,,) = launcher.predict(creator, c);
        LodestarFactory.DeployParams memory d = _deployParams(predicted, c.quote);
        d.creatorLockUntil = lockUntil;
        vm.prank(creator);
        address router;
        (token, poolId, router) = launcher.launch(c, d, _profile(), plan);
        l = Lodestar(payable(router));
    }

    function _escrow(bytes32 poolId) internal view returns (IAscendV5Escrow) {
        return IAscendV5Escrow(IAscendV5EscrowFactory(ESCROW_FACTORY).escrowOf(poolId));
    }

    function test_launchesWithTheRouterAsFeeOwner() public {
        AscendV5Launcher.Coin memory c = _coin(50_000, 1 ether);
        (address pToken, bytes32 pPool, address pRouter) = launcher.predict(creator, c);
        uint256 whypeBefore = IERC20(WHYPE).balanceOf(creator);
        (address token, bytes32 poolId, Lodestar l) = _launch(c, type(uint64).max, "");

        assertEq(token, pToken, "the predicted coin");
        assertEq(poolId, pPool, "the predicted pool");
        assertEq(address(l), pRouter, "the predicted router");
        (address viaFactory,) = factory.predict(token, WHYPE);
        assertEq(viaFactory, address(l), "the factory agrees");

        IAscendV5Escrow e = _escrow(poolId);
        assertEq(e.recipient(), address(l), "the escrow pays the router from the start");
        assertEq(e.pendingRecipient(), address(0), "nothing to wait for");
        assertEq(e.ctoRegistry(), address(0), "no community takeovers");
        assertTrue(l.isCreator());
        assertTrue(l.creatorRoleLocked(), "the lock binds at once");
        assertEq(l.steward(), creator);
        assertEq(factory.lodestarOf(token), address(l));
        assertEq(launcher.launcherOf(token), creator);
        assertEq(IAscendV5Launchpad(LAUNCHPAD).currentFee(poolId), 50_000, "the creator's 5% fee");

        assertGt(IERC20(token).balanceOf(creator), 0, "the dev buy went to the creator");
        uint256 spent = whypeBefore - IERC20(WHYPE).balanceOf(creator);
        assertGt(spent, 0);
        assertLe(spent, 1 ether, "what the dev buy didn't spend came back");
        assertEq(IERC20(WHYPE).balanceOf(address(launcher)), 0, "the launcher keeps nothing");
        assertEq(IERC20(WHYPE).allowance(address(launcher), ESCROW_FACTORY), 0);

        vm.prank(creator);
        vm.expectRevert(Lodestar.CreatorRoleIsLocked.selector);
        l.transferCreatorOut(creator);
    }

    function test_feesReachTheRouterFromTheFirstTrade() public {
        (address token, bytes32 poolId, Lodestar l) = _launch(_coin(30_000, 0), type(uint64).max, "");
        IAscendV5Escrow e = _escrow(poolId);
        for (uint256 i; i < 10; ++i) {
            vm.prank(trader);
            v5swapper.buyExactIn(poolId, 20 ether, 0, locker);
            skip(6 minutes);
        }
        _lock(token, l.exilePoolId(), IERC20(token).balanceOf(locker));
        l.distribute{gas: 3_000_000}();
        uint256 routed =
            l.totalHoldersQuote() + l.totalTreasuryQuote() + l.totalBuybackQuote() + l.buybackReserve();
        assertGt(routed, 0, "the router was paid");
        assertGt(l.totalHoldersQuote(), 0, "lockers were paid");
        assertGt(l.totalTreasuryQuote(), 0, "the Team Treasury stream was paid");
        assertEq(e.claimable(creator), 0, "no creator fee ever goes to a wallet");
    }

    function test_everyFeeChoice() public {
        uint24[4] memory fees = [uint24(10_000), 30_000, 50_000, 100_000];
        for (uint256 i; i < fees.length; ++i) {
            AscendV5Launcher.Coin memory c = _coin(fees[i], 0);
            c.salt = bytes32(i);
            (, bytes32 poolId, Lodestar l) = _launch(c, 0, "");
            assertEq(IAscendV5Launchpad(LAUNCHPAD).currentFee(poolId), fees[i]);
            assertEq(source.swapCostBps(address(0), poolId), fees[i] / 100);
            assertTrue(l.isCreator());
        }
    }

    function test_usdcPair() public {
        AscendV5Launcher.Coin memory c = _coin(30_000, 0);
        c.quote = USDC;
        (address token, bytes32 poolId, Lodestar l) = _launch(c, 0, "");
        assertTrue(l.isCreator());
        assertEq(_escrow(poolId).quote(), USDC);
        assertEq(factory.lodestarOf(token), address(l));
    }

    function test_devBuyInNativeHype() public {
        AscendV5Launcher.Coin memory c = _coin(30_000, 2 ether);
        (address predicted,,) = launcher.predict(creator, c);
        LodestarFactory.DeployParams memory d = _deployParams(predicted, WHYPE);
        uint256 whypeBefore = IERC20(WHYPE).balanceOf(creator);
        vm.prank(creator);
        vm.expectRevert(AscendV5Launcher.BadValue.selector);
        launcher.launch{value: 1 ether}(c, d, _profile(), "");
        vm.prank(creator);
        (address token,,) = launcher.launch{value: 2 ether}(c, d, _profile(), "");
        assertGt(IERC20(token).balanceOf(creator), 0);
        assertGe(IERC20(WHYPE).balanceOf(creator), whypeBefore, "only HYPE paid; leftovers back as WHYPE");
        assertEq(address(launcher).balance, 0);
    }

    function test_launchStatementRidesAlong() public {
        AscendV5Launcher.Coin memory c = _coin(30_000, 0);
        (address predicted,, address router) = launcher.predict(creator, c);
        string memory plan = "Dev buy is the team's; none of it is sold for 30 days.";
        IAscendV5EscrowFactory.LaunchParams memory p = IAscendV5EscrowFactory.LaunchParams({
            name: c.name,
            symbol: c.symbol,
            quote: c.quote,
            devBuyQuote: 0,
            minDevOut: 0,
            salt: keccak256(abi.encode(creator, c.salt)),
            creator: address(0),
            fee: c.fee,
            builderFee: 0
        });
        IAscendV5EscrowFactory.Route memory r =
            IAscendV5EscrowFactory.Route(router, creator, address(0), false);
        bytes memory expected = bytes.concat(
            abi.encodeCall(IAscendV5EscrowFactory.launch, (p, r)),
            abi.encode(bytes32("ascend.disclosure.v1"), "", plan)
        );
        vm.expectCall(ESCROW_FACTORY, expected);
        LodestarFactory.DeployParams memory d = _deployParams(predicted, WHYPE);
        vm.prank(creator);
        launcher.launch(c, d, _profile(), plan);
    }

    function test_aCopiedLaunchGetsAnotherCoin() public {
        AscendV5Launcher.Coin memory c = _coin(30_000, 0);
        (address mine,,) = launcher.predict(creator, c);
        (address theirs,,) = launcher.predict(trader, c);
        assertTrue(mine != theirs);
        // the copier can't use the creator's deploy params: they name the creator's coin
        LodestarFactory.DeployParams memory d = _deployParams(mine, WHYPE);
        vm.prank(trader);
        vm.expectRevert(AscendV5Launcher.WrongDeployParams.selector);
        launcher.launch(c, d, _profile(), "");
    }

    function test_onlyTheLauncherDeploysLaunched() public {
        (address token,,) = launcher.predict(creator, _coin(30_000, 0));
        LodestarFactory.DeployParams memory d = _deployParams(token, WHYPE);
        vm.expectRevert(LodestarFactory.OnlyLauncher.selector);
        factory.deployLaunched(d, creator);
        vm.prank(creator);
        vm.expectRevert(LodestarFactory.OnlyOwner.selector);
        factory.setLauncher(creator);
    }

    /// @dev Even the launcher can't make a router for a coin whose escrow pays someone else.
    function test_launcherCantTakeOtherCoins() public {
        LodestarFactory.DeployParams memory d = _deployParams(COIN_3, WHYPE);
        vm.prank(address(launcher));
        vm.expectRevert(LodestarFactory.NotLaunchedToRouter.selector);
        factory.deployLaunched(d, creator);
    }

    function test_profile() public {
        (address token,, Lodestar l) = _launch(_coin(30_000, 0), 0, "");
        AscendV5Launcher.Profile memory p = launcher.profileOf(token);
        assertEq(p.image, _profile().image);
        assertEq(p.website, "https://example.com");

        p.twitter = "https://x.com/example";
        vm.prank(trader);
        vm.expectRevert(AscendV5Launcher.NotSteward.selector);
        launcher.setProfile(token, p);
        vm.prank(l.steward());
        launcher.setProfile(token, p);
        assertEq(launcher.profileOf(token).twitter, "https://x.com/example");

        p.description = string(new bytes(1001));
        vm.prank(l.steward());
        vm.expectRevert(AscendV5Launcher.TooLong.selector);
        launcher.setProfile(token, p);
        vm.expectRevert(AscendV5Launcher.NotLaunchedHere.selector);
        launcher.setProfile(COIN_3, p);
    }
}
