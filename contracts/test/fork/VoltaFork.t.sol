// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {VoltaFeeSource} from "../../src/sources/VoltaFeeSource.sol";
import {V4FeeSource} from "../../src/sources/V4FeeSource.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {
    IVoltaPositionManager,
    IVoltaCreatorNFT,
    IVoltaFeeEscrow,
    IVoltaToken
} from "../../src/interfaces/ILaunchpadHooks.sol";

interface IVoltaFeeExecutor {
    function isContract(address account) external view returns (bool);
}

/// @notice Lodestar on Volta (volta.family) against its real PositionManager, creator NFT and fee escrow on an
/// Elysium mainnet fork.
contract VoltaForkTest is ForkBase {
    address internal constant PM = 0x3aB88DDc3CF2A012af88B60828edb4553697E5dC; // PositionManager, every pool's hook
    address internal constant NFT = 0xac466Ee5CEdD012eB750DBDA0B935F8B997402c7; // the creator NFT
    address internal constant ESCROW = 0x3D36Beb546E451584736957F97E7EE9D2aCbD9a5; // native HYPE fee escrow
    address internal constant FEE_EXECUTOR = 0xD68D650DAFb9BA8517DA430f7f0a94e942E89c41;
    address internal constant POOL_MANAGER = 0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1; // the official one

    // 1% fee, half of the creator side to the creator, half to buyback
    address internal constant VOID = 0xD31B21Cb80E431AC996269deC31A40fCf048B77f;
    // 3% fee, all of the creator side to the creator
    address internal constant ETF = 0x3B050A7C1039FEF56e9c241608953D6E6d5c1D9E;
    // 2% fee: 90% creator, 5% buyback, 5% holders
    address internal constant SATN = 0x71aD0ea00fd754C4e9118a7Fc75d2c05C9bB8797;
    // Volta's own coin: all of the creator side to buyback, nothing to route
    address internal constant VOLTA = 0x0f79931689Af199e7CF868ed1107bBA2C83c68f7;
    // quoted in KNTQ
    address internal constant KMEOW = 0xC8567e00872fB9fE8fAA5749556A19fC91a479DD;
    // an ElysPump coin: no creator NFT
    address internal constant ELYSP = 0x7a7AE0e715867fc3b0055192624982017328c60B;

    VoltaFeeSource internal source;
    LodestarFactory internal factory;

    function setUp() public {
        if (!_fork()) return;
        address[] memory hooks = new address[](1);
        uint8[] memory kinds = new uint8[](1);
        (hooks[0], kinds[0]) = (PM, 1);
        source = new VoltaFeeSource(observer, address(this), hooks, kinds);
        factory = _factory(IFeeSource(address(source)));
    }

    function _id(address coin) internal view returns (uint256 id) {
        (, id) = source.creatorNft(coin);
    }

    function _owedTo(address coin, address who) internal view returns (uint256 q) {
        (, q) = source.owed(coin, bytes32(0), who);
    }

    /// @dev Volta is one-step: deploy, then send the creator NFT to the router.
    function _activate(address coin, address swapper) internal returns (Lodestar l) {
        address dev = source.creator(coin, bytes32(0));
        vm.prank(dev);
        l = Lodestar(payable(factory.deploy(_params(coin, swapper))));
        uint256 id = _id(coin);
        vm.prank(dev);
        IVoltaCreatorNFT(NFT).transferFrom(dev, address(l), id);
        assertTrue(l.isCreator(), "router holds the role");
        assertEq(IVoltaToken(coin).creator(), address(l), "the coin names its new creator");
    }

    function test_registryAndViews() public view {
        (uint8 kind, address pm) = source.hooks(PM);
        assertEq(kind, 1);
        assertEq(pm, POOL_MANAGER);
        (bytes32 id, address hook, bool tokenIs0) = source.resolve(VOID, address(0));
        assertEq(hook, NFT, "the router's hook is the NFT that holds the role");
        assertFalse(tokenIs0);
        assertEq(id, keccak256(abi.encode(IVoltaPositionManager(PM).poolKey(VOID))));
        assertEq(source.payer(VOID), ESCROW, "the escrow pays the role's fees");
        (address nft, uint256 nid) = source.creatorNft(VOID);
        assertEq(nft, NFT);
        assertEq(IVoltaCreatorNFT(NFT).memecoin(nid), VOID);
        assertEq(source.creator(VOID, id), IVoltaCreatorNFT(NFT).ownerOf(nid));
        (uint256 c, uint256 b, uint256 h) = source.split(SATN);
        assertEq(c, 9000);
        assertEq(b, 500);
        assertEq(h, 500);
        assertEq(source.creatorShareBps(VOID), 5000);
        assertEq(source.swapCostBps(VOID, id), 100);
        assertEq(source.swapCostBps(ETF, bytes32(0)), 300);
        assertEq(source.holdersShareBps(SATN, bytes32(0)), 0, "Volta pays holders as wallets only");
        (address target, bytes4 sel) = source.dividendClaim(SATN);
        assertEq(target, address(0));
        assertEq(sel, bytes4(0));
        assertEq(source.burnSink(VOID), DEAD);
        assertTrue(source.handover() == IFeeSource.Handover.OneStep);
        (uint160 spot,, uint128 liq) = source.prices(VOID, id);
        assertGt(spot, 0);
        assertGt(liq, 0);
    }

    function test_refusesWhatItCantRoute() public {
        vm.expectRevert(VoltaFeeSource.NoCreatorShare.selector);
        source.resolve(VOLTA, address(0));
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(KMEOW, address(0));
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        source.resolve(VOID, makeAddr("someQuote"));
        vm.expectRevert(V4FeeSource.UnsupportedHook.selector);
        source.resolve(ELYSP, address(0));

        address dev = source.creator(VOLTA, bytes32(0));
        vm.prank(dev);
        vm.expectRevert(VoltaFeeSource.NoCreatorShare.selector);
        factory.deploy(_params(VOLTA, address(0)));
    }

    /// @dev A token that names Volta's NFT but wasn't launched by it borrows nothing.
    function test_refusesALookalike() public {
        LookalikeToken fake = new LookalikeToken(NFT);
        vm.expectRevert(VoltaFeeSource.UnknownCoin.selector);
        source.resolve(address(fake), address(0));
    }

    /// @dev Volta credits the creator's share to whoever holds the NFT when a pool's fees are distributed, by
    /// address: what the dev was credited before handing over stays the dev's.
    function _claimAndDistribute(address coin) internal returns (Lodestar l, uint256 routed) {
        address dev = source.creator(coin, bytes32(0));
        uint256 devOwed = _owedTo(coin, dev);
        l = _activate(coin, address(0));
        assertEq(l.hook(), NFT);
        assertEq(l.payer(), ESCROW);
        assertEq(_owedTo(coin, dev), devOwed, "the dev's earlier fees stay the dev's");
        assertEq(_owedTo(coin, address(l)), 0);

        _volume(source, coin, 0.5 ether, 10);
        routed = _owedTo(coin, address(l));
        assertGt(routed, 0, "fees accrue to the router in the escrow");
        l.distribute();
        assertEq(_owedTo(coin, address(l)), 0, "withdrawFees paid the router");
        assertEq(l.totalHoldersQuote() + l.totalTreasuryQuote() + l.buybackReserve(), routed);
        assertEq(l.totalHoldersQuote(), routed * HOLDERS_BPS / 10_000);
        assertEq(_owedTo(coin, dev), devOwed, "and the dev can still withdraw theirs");
        uint256 before = dev.balance;
        vm.prank(dev);
        IVoltaFeeEscrow(ESCROW).withdrawFees(address(0), dev, false);
        assertEq(dev.balance - before, devOwed);
    }

    /// @dev The hook distributes a pool's fees once they reach 0.01 HYPE, so up to that much waits for the next
    /// trade; and buys first take coins the hook collected as fees (its internal swap pool), which turns earlier
    /// coin-side fees into HYPE for the NFT's holder. Hence the loose bounds.
    function test_claimAndDistribute() public {
        (, uint256 routed) = _claimAndDistribute(ETF);
        // 5 HYPE of buys at 3%: 30% to the protocol, all of the rest to the creator
        assertApproxEqRel(routed, 0.105 ether, 0.3e18);
    }

    function test_mixedSplit_claimAndDistribute() public {
        (, uint256 routed) = _claimAndDistribute(VOID);
        // the creator's half of the creator side: 5 HYPE * 1% * 70% * 50%
        assertApproxEqRel(routed, 0.0175 ether, 0.3e18);
    }

    function test_buybackThroughVoltasPool() public {
        Lodestar l = _activate(ETF, address(_swapper(POOL_MANAGER)));
        _volume(source, ETF, 0.5 ether, 10);
        uint256 deadBefore = IERC20(ETF).balanceOf(DEAD);
        l.distribute();
        skip(31 minutes);
        l.distribute();
        assertGt(l.totalBuybackTokensBurned(), 0, "bought back on Volta's pool, net of its swap fee");
        assertEq(IERC20(ETF).balanceOf(DEAD) - deadBefore, l.totalBuybackTokensBurned());
    }

    /// @dev Volta's fee executor pays holder rewards to wallets only, so Exile isn't one of the holders and the
    /// router has no harvest to name.
    function test_noHarvestForExile() public {
        Lodestar l = _activate(SATN, address(0));
        (uint256 hPool, address target, bytes4 sel) = exile.harvestOf(SATN);
        assertEq(hPool, 0);
        assertEq(target, address(0));
        assertEq(sel, bytes4(0));
        assertTrue(IVoltaFeeExecutor(FEE_EXECUTOR).isContract(address(exile)), "Exile is a contract to Volta");
        assertGt(l.exilePoolId(), 0, "lockers still earn the router's holder share");
    }

    function test_strangerCannotDeploy() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(ETF, address(0)));
    }

    function test_onlyTheHolderMovesTheNft() public {
        uint256 id = _id(ETF);
        address dev = source.creator(ETF, bytes32(0));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        IVoltaCreatorNFT(NFT).transferFrom(dev, makeAddr("stranger"), id);
    }

    function test_stewardHandsTheRoleBack() public {
        Lodestar l = _activate(ETF, address(0));
        address next = makeAddr("next");
        vm.prank(l.steward());
        l.transferCreatorOut(next);
        assertEq(source.creator(ETF, bytes32(0)), next);
        assertEq(IVoltaCreatorNFT(NFT).ownerOf(_id(ETF)), next);
        assertFalse(l.isCreator());
    }

    /// @dev ETF's creator sends its NFT to VOID's router. The escrow keys fees by address, so VOID's router would
    /// collect ETF's fees for its own lockers; the owner moves the NFT into ETF's own router.
    function test_roleSentToAnotherCoinsRouterIsRescued() public {
        Lodestar voidRouter = _activate(VOID, address(0));
        address dev = source.creator(ETF, bytes32(0));
        uint256 id = _id(ETF);
        vm.prank(dev);
        IVoltaCreatorNFT(NFT).transferFrom(dev, address(voidRouter), id);
        vm.prank(dev);
        vm.expectRevert(LodestarFactory.NotPoolCreator.selector);
        factory.deploy(_params(ETF, address(0)));

        Lodestar etf = Lodestar(payable(factory.rescueDeploy(_params(ETF, address(0)), dev)));
        assertEq(source.creator(ETF, bytes32(0)), address(etf));
        assertTrue(etf.isCreator());
        assertTrue(voidRouter.isCreator(), "VOID's router keeps its own role");
        _volume(source, ETF, 0.5 ether, 4);
        assertGt(_owedTo(ETF, address(etf)), 0, "ETF's fees now accrue to ETF's router");
    }
}

/// @dev Names Volta's creator NFT as its own, like a Volta coin, without having been launched by it.
contract LookalikeToken {
    address public immutable flaunch;

    constructor(address nft) {
        flaunch = nft;
    }
}
