// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {V4PriceObserver} from "../src/V4PriceObserver.sol";
import {V4Swapper} from "../src/V4Swapper.sol";
import {V4State} from "../src/libraries/V4State.sol";
import {IV4PoolManager, V4PoolKey} from "../src/interfaces/IUniswapV4.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockV4PoolManager, MockNativeHook} from "./utils/NativeMocks.sol";
import {V4FeeSource} from "../src/sources/V4FeeSource.sol";
import {MontraFeeSource} from "../src/sources/MontraFeeSource.sol";
import {BoxaFeeSource} from "../src/sources/BoxaFeeSource.sol";

contract V4StateReader {
    function read(IV4PoolManager pm, bytes32 id) external view returns (uint160, int24, uint24, uint128) {
        (uint160 p, int24 t, uint24 f) = V4State.slot0(pm, id);
        return (p, t, f, V4State.liquidity(pm, id));
    }
}

/// @notice The Uniswap v4 pieces: storage reads, the price observer and the buyback swapper.
contract V4Test is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint160 internal constant P = uint160(1 << 96);

    MockERC20 internal token;
    MockV4PoolManager internal pm;
    V4PriceObserver internal obs;
    V4Swapper internal swapper;
    V4PoolKey internal key;
    bytes32 internal id;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockERC20("Coin", "COIN", 18);
        pm = new MockV4PoolManager(token);
        obs = new V4PriceObserver();
        swapper = new V4Swapper(IV4PoolManager(address(pm)), obs);
        key = V4PoolKey(address(0), address(token), 0, 200, address(0x1234));
        id = keccak256(abi.encode(key));
        pm.setPool(id, P, -12_345, 0, 1e24);
    }

    // ---------------------------------------------------------------- V4State

    function test_readsSlot0AndLiquidity() public {
        pm.setPool(id, 123456789, -887_000, 3000, 42);
        (uint160 p, int24 t, uint24 f, uint128 l) = new V4StateReader().read(IV4PoolManager(address(pm)), id);
        assertEq(p, 123456789);
        assertEq(t, -887_000);
        assertEq(f, 3000);
        assertEq(l, 42);
    }

    // ---------------------------------------------------------------- observer

    function test_averageNeedsAFullWindow() public {
        obs.poke(address(pm), key);
        assertEq(obs.ema(address(pm), id), 0);
        skip(30 minutes - 1);
        assertEq(obs.ema(address(pm), id), 0);
        skip(1);
        assertEq(obs.ema(address(pm), id), P);
        assertEq(obs.keyOf(address(pm), id).currency1, address(token));
    }

    function test_averageFollowsTimeWeightedSpot() public {
        obs.poke(address(pm), key);
        skip(30 minutes);
        pm.setPool(id, 2 * P, 0, 0, 1e24);
        obs.poke(address(pm), key); // the new spot has held for no time yet
        assertEq(obs.ema(address(pm), id), P);
        skip(15 minutes);
        assertEq(obs.ema(address(pm), id), P + P / 2, "halfway after half a window");
        skip(15 minutes);
        assertEq(obs.ema(address(pm), id), 2 * P);
    }

    function test_oneObservationPerSecond() public {
        obs.poke(address(pm), key);
        skip(30 minutes);
        obs.poke(address(pm), key);
        // a pump and a poke in the same second change nothing the next buyback would read
        pm.setPool(id, 4 * P, 0, 0, 1e24);
        obs.poke(address(pm), key);
        V4PriceObserver.Observation memory o = obs.observation(address(pm), id);
        assertEq(o.last, P);
        skip(1);
        assertLt(obs.ema(address(pm), id), P + P / 1000);
    }

    function test_uninitializedPoolHasNoPrice() public {
        V4PoolKey memory other = V4PoolKey(address(0), address(0xBEEF), 0, 200, address(0x1234));
        assertEq(obs.poke(address(pm), other), 0);
        skip(1 hours);
        assertEq(obs.ema(address(pm), keccak256(abi.encode(other))), 0);
    }

    // ---------------------------------------------------------------- swapper

    function test_buyExactInSendsCoinsToTheSink() public {
        obs.poke(address(pm), key);
        pm.setSwap(2e18, 100, 10_000); // 2 coins per wei, 1% tax
        uint256 out = swapper.buyExactIn{value: 1 ether}(id, 1 ether, 1.98 ether, DEAD);
        assertEq(out, 1.98 ether);
        assertEq(token.balanceOf(DEAD), 1.98 ether);
        assertEq(address(swapper).balance, 0);
        assertEq(address(pm).balance, 1 ether);
    }

    function test_buyRefundsWhatThePoolDidNotTake() public {
        obs.poke(address(pm), key);
        pm.setSwap(1e18, 0, 5_000);
        uint256 before = address(this).balance;
        swapper.buyExactIn{value: 1 ether}(id, 1 ether, 0, DEAD);
        assertEq(before - address(this).balance, 0.5 ether);
    }

    function test_buyChecksItsInputs() public {
        vm.expectRevert(V4Swapper.UnknownPool.selector);
        swapper.buyExactIn{value: 1}(id, 1, 0, DEAD);
        obs.poke(address(pm), key);
        vm.expectRevert(V4Swapper.ZeroAmount.selector);
        swapper.buyExactIn(id, 0, 0, DEAD);
        vm.expectRevert(V4Swapper.WrongValue.selector);
        swapper.buyExactIn{value: 1}(id, 2, 0, DEAD);
        pm.setSwap(1e18, 0, 10_000);
        vm.expectRevert(abi.encodeWithSelector(V4Swapper.Slippage.selector, 1 ether, 1 ether + 1));
        swapper.buyExactIn{value: 1 ether}(id, 1 ether, 1 ether + 1, DEAD);
    }

    function test_buyRefusesAPoolNotQuotedInHype() public {
        V4PoolKey memory k = V4PoolKey(address(0xAAAA), address(token), 0, 200, address(0x1234));
        bytes32 kid = keccak256(abi.encode(k));
        pm.setPool(kid, P, 0, 0, 1e24);
        obs.poke(address(pm), k);
        vm.expectRevert(V4Swapper.NotNativePool.selector);
        swapper.buyExactIn{value: 1}(kid, 1, 0, DEAD);
    }

    function test_onlyThePoolManagerCallsBack() public {
        vm.expectRevert(V4Swapper.OnlyPoolManager.selector);
        swapper.unlockCallback(abi.encode(key, uint256(1), uint256(0), DEAD));
    }

    // ---------------------------------------------------------------- adapter hook registry

    function test_registryIsAddOnlyAndOwned() public {
        MockNativeHook h1 = new MockNativeHook();
        MockNativeHook h2 = new MockNativeHook();
        address[] memory hooks = new address[](1);
        hooks[0] = address(h1);
        uint8[] memory kinds = new uint8[](1);
        kinds[0] = 1;
        BoxaFeeSource src = new BoxaFeeSource(obs, address(this), hooks, kinds);
        (uint8 kind, address hpm) = src.hooks(address(h1));
        assertEq(kind, 1);
        assertEq(hpm, h1.poolManager());
        assertEq(src.hookCount(), 1);

        vm.expectRevert(V4FeeSource.KnownHook.selector);
        src.addHook(address(h1), 2);
        vm.expectRevert(V4FeeSource.BadKind.selector);
        src.addHook(address(h2), 0);
        vm.expectRevert(V4FeeSource.BadKind.selector);
        src.addHook(address(h2), 4);
        vm.expectRevert(V4FeeSource.ZeroAddress.selector);
        src.addHook(address(0), 1);
        vm.prank(address(0xBAD));
        vm.expectRevert(V4FeeSource.OnlyOwner.selector);
        src.addHook(address(h2), 3);
        src.addHook(address(h2), 3);
        assertEq(src.hookCount(), 2);

        src.transferOwner(address(0xB0B));
        vm.prank(address(0xBAD));
        vm.expectRevert(V4FeeSource.NotPendingOwner.selector);
        src.acceptOwner();
        vm.prank(address(0xB0B));
        src.acceptOwner();
        assertEq(src.owner(), address(0xB0B));
    }

    function test_unknownHookIsUnsupported() public {
        MontraFeeSource src = new MontraFeeSource(obs, address(this), new address[](0), new uint8[](0));
        vm.expectRevert(V4FeeSource.UnsupportedHook.selector);
        src.hookOf(address(token)); // a coin with no hook() at all
        vm.expectRevert(V4FeeSource.QuoteUnsupported.selector);
        src.resolve(address(token), address(0xBEEF));
    }

    function test_registryNeedsMatchingLists() public {
        vm.expectRevert(V4FeeSource.BadKind.selector);
        new MontraFeeSource(obs, address(this), new address[](1), new uint8[](0));
        vm.expectRevert(V4FeeSource.ZeroAddress.selector);
        new MontraFeeSource(obs, address(0), new address[](0), new uint8[](0));
    }

    receive() external payable {}
}
