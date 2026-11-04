// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseScript} from "./Base.s.sol";
import {console2} from "forge-std/Script.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {AscendSwapper} from "../src/AscendSwapper.sol";
import {Lodestar} from "../src/Lodestar.sol";
import {Exile} from "../src/Exile.sol";
import {Sandfall} from "../src/Sandfall.sol";
import {ILodestar} from "../src/interfaces/ILodestar.sol";

/// @notice Populates a chain for the demo after ActivateLodestar: two holders buy and lock MONARCH,
/// some volume generates fees, Lodestar distributes, and the dev creates one cancellable and one
/// non-cancellable vest. Wallets come from PRIVATE_KEY (dev), ALICE_KEY and BOB_KEY; on anvil they
/// default to its first three accounts.
contract DemoFlow is BaseScript {
    uint256 internal constant ANVIL_1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant ANVIL_2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;

    Deployment internal d;
    MockERC20 internal usdc;
    MockERC20 internal monarch;
    AscendSwapper internal swapper;

    function run() external {
        d = _load();
        require(d.lodestar != address(0), "run ActivateLodestar first");
        usdc = MockERC20(d.quote);
        monarch = MockERC20(d.token);
        swapper = AscendSwapper(d.swapper);
        Lodestar l = Lodestar(payable(d.lodestar));
        Exile exile = Exile(payable(d.exile));
        uint256 exilePool = l.exilePoolId();

        uint256 devKey = _deployerKey();
        uint256 aliceKey = vm.envOr("ALICE_KEY", block.chainid == 31337 ? ANVIL_1 : 0);
        uint256 bobKey = vm.envOr("BOB_KEY", block.chainid == 31337 ? ANVIL_2 : 0);
        require(aliceKey != 0 && bobKey != 0, "set ALICE_KEY and BOB_KEY");
        address alice = vm.addr(aliceKey);

        // holders buy and lock: Alice takes the crown (30 days, 4x), Bob starts as a Peasant (1 day, 0.5x)
        uint256 aliceTokens = _buy(aliceKey, 2_000e6);
        uint256 bobTokens = _buy(bobKey, 1_000e6);
        vm.startBroadcast(aliceKey);
        monarch.approve(address(exile), aliceTokens);
        exile.lockERC20(address(monarch), aliceTokens, uint64(block.timestamp + 30 days + 1 hours), exilePool);
        vm.stopBroadcast();
        vm.startBroadcast(bobKey);
        monarch.approve(address(exile), bobTokens);
        exile.lockERC20(address(monarch), bobTokens, uint64(block.timestamp + 1 days + 1 hours), exilePool);
        vm.stopBroadcast();

        // volume from the dev wallet
        for (uint256 i; i < 4; ++i) {
            uint256 got = _buy(devKey, 5_000e6);
            vm.startBroadcast(devKey);
            monarch.approve(address(swapper), got / 2);
            swapper.sellExactIn(d.poolId, got / 2, 0, vm.addr(devKey));
            vm.stopBroadcast();
        }

        // anyone can route the fees
        vm.startBroadcast(bobKey);
        l.distribute();
        vm.stopBroadcast();

        // two contributor vests to Alice: one cancellable, one not
        Sandfall sandfall = Sandfall(d.sandfall);
        vm.startBroadcast(devKey);
        usdc.mint(vm.addr(devKey), 3_000e6);
        usdc.approve(address(sandfall), 3_000e6);
        uint64 nowTs = uint64(block.timestamp);
        sandfall.createFixed(d.quote, alice, 2_000e6, nowTs, nowTs + 1 days, nowTs + 30 days, 0, true);
        sandfall.createFixed(d.quote, alice, 1_000e6, nowTs, nowTs, nowTs + 90 days, 30 days, false);
        // a pending split change, to show the 12h timelock
        l.proposeConfig(ILodestar.Config(3_000, 5_000, 2_000, l.config().swapper, 300, false));
        vm.stopBroadcast();

        console2.log("burned (fees)", l.totalTokenBurned());
        console2.log("burned (buyback)", l.totalBuybackTokensBurned());
        console2.log("holder rewards (quote)", l.totalHoldersQuote());
        console2.log("treasury (quote)", l.totalTreasuryQuote());
    }

    function _buy(uint256 key, uint256 quoteIn) internal returns (uint256 out) {
        address who = vm.addr(key);
        vm.startBroadcast(key);
        usdc.mint(who, quoteIn);
        usdc.approve(address(swapper), quoteIn);
        out = swapper.buyExactIn(d.poolId, quoteIn, 0, who);
        vm.stopBroadcast();
    }
}
