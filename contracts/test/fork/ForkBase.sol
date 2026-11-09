// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Exile} from "../../src/Exile.sol";
import {Sandfall} from "../../src/Sandfall.sol";
import {Lodestar} from "../../src/Lodestar.sol";
import {LodestarFactory} from "../../src/LodestarFactory.sol";
import {V4PriceObserver} from "../../src/V4PriceObserver.sol";
import {V4Swapper} from "../../src/V4Swapper.sol";
import {ILodestar} from "../../src/interfaces/ILodestar.sol";
import {ISandfall} from "../../src/interfaces/ISandfall.sol";
import {IFeeSource} from "../../src/interfaces/IFeeSource.sol";
import {IV4PoolManager, V4PoolKey} from "../../src/interfaces/IUniswapV4.sol";
import {V4FeeSource} from "../../src/sources/V4FeeSource.sol";
import {MonarchTiers} from "../../src/libraries/MonarchTiers.sol";
import {MockArbSys} from "../../src/mocks/MockArbSys.sol";

/// @notice Monarchy core on a fork of Elysium mainnet (chain 99901), against the launchpads' real contracts.
/// Set ELYSIUM_RPC_URL to run (for example https://rpc.eleos.fun); without it every fork test is skipped.
/// ELYSIUM_FORK_BLOCK pins a block. Nothing here is broadcast: forge forks the chain into a local EVM.
abstract contract ForkBase is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant ARB_SYS = 0x0000000000000000000000000000000000000064;
    uint16 internal constant BURN_BPS = 2000;
    uint16 internal constant HOLDERS_BPS = 5000;
    uint16 internal constant TREASURY_BPS = 3000;

    Exile internal exile;
    Sandfall internal sandfall;
    Lodestar internal impl;
    V4PriceObserver internal observer;

    address internal treasury = makeAddr("treasury");
    address internal locker = makeAddr("locker");
    address internal trader = makeAddr("trader");

    mapping(address pm => V4Swapper) internal swapperOf;

    /// @dev False (and the test skipped) when no RPC is configured.
    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("ELYSIUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        uint256 blk = vm.envOr("ELYSIUM_FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
        assertEq(block.chainid, 99901, "not Elysium mainnet");
        vm.etch(ARB_SYS, type(MockArbSys).runtimeCode);
        exile = new Exile();
        sandfall = new Sandfall();
        impl = new Lodestar();
        observer = new V4PriceObserver();
        vm.deal(trader, 10_000 ether);
        return true;
    }

    function _factory(IFeeSource source) internal returns (LodestarFactory f) {
        f = new LodestarFactory(
            address(impl), source, exile, ISandfall(address(sandfall)), address(0), address(this)
        );
        // the factory names harvest pools, so it becomes an Exile registrar behind the 12 hour timelock
        exile.proposeRegistrar(address(f));
        skip(12 hours);
        exile.addRegistrar(address(f));
    }

    function _swapper(address pm) internal returns (V4Swapper s) {
        s = swapperOf[pm];
        if (address(s) == address(0)) {
            s = new V4Swapper(IV4PoolManager(pm), observer);
            swapperOf[pm] = s;
        }
    }

    /// @dev The default split decided for these launchpads: 20% buyback-and-burn, 50% lockers, 30% treasury.
    function _params(address token, address swapper)
        internal
        view
        returns (LodestarFactory.DeployParams memory p)
    {
        p.token = token;
        p.quote = address(0);
        p.cfg = ILodestar.Config({
            burnBps: BURN_BPS,
            holdersBps: HOLDERS_BPS,
            treasuryBps: TREASURY_BPS,
            swapper: swapper,
            maxSlippageBps: 300,
            tokenToHolders: false
        });
        p.treasuryRecipient = treasury;
        p.treasuryWindow = 30 days;
        p.tiers = MonarchTiers.defaults();
    }

    /// @dev A real buy through the coin's pool, HYPE in, coins to `to`. Registers the pool with the observer first.
    function _buy(V4FeeSource source, address token, uint256 hypeIn, address to)
        internal
        returns (uint256 out)
    {
        (, V4FeeSource.HookInfo memory info) = source.hookOf(token);
        V4PoolKey memory key = source.poolKey(token);
        observer.poke(info.poolManager, key);
        V4Swapper s = _swapper(info.poolManager);
        vm.prank(trader);
        out = s.buyExactIn{value: hypeIn}(keccak256(abi.encode(key)), hypeIn, 0, to);
    }

    /// @dev Buys spread over time, then a pause, so a hook or a price observer that checks a price average sees a
    /// market rather than one jump.
    function _volume(V4FeeSource source, address token, uint256 hypeEach, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _buy(source, token, hypeEach, DEAD);
            skip(2 minutes);
        }
        skip(20 minutes);
    }

    function _lock(address token, uint256 poolId, uint256 amount) internal returns (uint256 lockId) {
        vm.startPrank(locker);
        IERC20(token).approve(address(exile), amount);
        lockId = exile.lockERC20(token, amount, uint64(block.timestamp + 30 days), poolId);
        vm.stopPrank();
    }

    function _streamClaimable(Lodestar l) internal view returns (uint256) {
        return sandfall.claimable(l.treasuryStreamId());
    }
}
