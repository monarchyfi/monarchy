// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseScript} from "./Base.s.sol";
import {console2} from "forge-std/Script.sol";
import {Exile} from "../src/Exile.sol";
import {Sandfall} from "../src/Sandfall.sol";
import {Lodestar} from "../src/Lodestar.sol";
import {LodestarFactory} from "../src/LodestarFactory.sol";
import {AscendSwapper} from "../src/AscendSwapper.sol";
import {IAscendLaunchpad} from "../src/interfaces/IAscendLaunchpad.sol";
import {IListingDesk} from "../src/interfaces/IListingDesk.sol";
import {ICLPoolManager, IVault} from "../src/interfaces/IInfinity.sol";
import {IExile} from "../src/interfaces/IExile.sol";
import {ISandfall} from "../src/interfaces/ISandfall.sol";
import {IFeeSource} from "../src/interfaces/IFeeSource.sol";
import {AscendFeeSource} from "../src/sources/AscendFeeSource.sol";

/// @notice Deploys Exile, Sandfall, the Lodestar implementation, AscendSwapper, the Ascend fee-source adapter and
/// LodestarFactory.
/// ASCEND_MODE=real (default) points at Ascend on Elysium testnet from env; ASCEND_MODE=mock points at
/// the contracts DeployMocks wrote to deployments/<chainId>.json.
contract DeployCore is BaseScript {
    function run() external {
        string memory mode = vm.envOr("ASCEND_MODE", string("real"));
        Deployment memory d = _load();
        _guardOverwrite(d);

        if (keccak256(bytes(mode)) == keccak256("real")) {
            d.mode = "real";
            d.launchpad = vm.envAddress("ASCEND_LAUNCHPAD");
            d.desk = vm.envAddress("ASCEND_DESK");
            d.poolManager = vm.envAddress("CL_POOL_MANAGER");
            d.vault = vm.envAddress("INFINITY_VAULT");
            d.quote = vm.envAddress("QUOTE");
            d.startBlock = block.number;
        } else {
            require(d.launchpad != address(0), "run DeployMocks first");
        }
        require(d.launchpad.code.length > 0 && d.desk.code.length > 0, "launchpad/desk not deployed here");
        require(d.poolManager.code.length > 0 && d.vault.code.length > 0, "Infinity not deployed here");
        require(IAscendLaunchpad(d.launchpad).listingDesk() == d.desk, "desk is not the launchpad's");

        // The factory owner names the successor factory an upgrade moves a router to, and the default swapper.
        // On a live chain it must be a multisig (a contract), separate from every steward, so no single key
        // can start an upgrade; on the testnet and anvil the deployer may keep it for rehearsals.
        address owner = vm.envOr("FACTORY_OWNER", vm.addr(_deployerKey()));
        bool rehearsal = block.chainid == 99801 || block.chainid == 31337;
        require(
            owner.code.length > 0 || rehearsal || vm.envOr("ALLOW_EOA_OWNER", false),
            "FACTORY_OWNER must be a multisig on this chain (ALLOW_EOA_OWNER=true to override)"
        );

        vm.startBroadcast(_deployerKey());
        Exile exile = new Exile();
        Sandfall sandfall = new Sandfall();
        Lodestar impl = new Lodestar();
        AscendSwapper swapper =
            new AscendSwapper(IVault(d.vault), ICLPoolManager(d.poolManager), IAscendLaunchpad(d.launchpad));
        AscendFeeSource ascend = new AscendFeeSource(
            IAscendLaunchpad(d.launchpad), IListingDesk(d.desk), ICLPoolManager(d.poolManager)
        );
        LodestarFactory factory = new LodestarFactory(
            address(impl),
            IFeeSource(address(ascend)),
            IExile(address(exile)),
            ISandfall(address(sandfall)),
            address(swapper),
            owner
        );
        // Exile's owner only adds registrars for the harvest, which Ascend routers don't use; hand it to the same
        // owner as the factory (the owner accepts with Exile.acceptOwner)
        if (owner != vm.addr(_deployerKey())) exile.transferOwner(owner);
        vm.stopBroadcast();

        d.exile = address(exile);
        d.sandfall = address(sandfall);
        d.lodestarImpl = address(impl);
        d.swapper = address(swapper);
        d.factory = address(factory);
        _save(d);
        console2.log("factory", address(factory));
        console2.log("factory owner", owner);
    }
}
