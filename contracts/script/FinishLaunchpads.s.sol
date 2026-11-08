// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchpadsBase} from "./LaunchpadsBase.s.sol";
import {console2} from "forge-std/Script.sol";
import {Exile} from "../src/Exile.sol";

/// @notice Step 2 of 2: makes the Eleos, Kleos and Boxa factories Exile registrars once their 12 hour proposals
/// have matured. `addRegistrar` is permissionless after the timelock, so any funded key can run this (PRIVATE_KEY).
/// Routers can activate from then on. Ascend v5's factory never needs the role (its coins pay no holder dividends),
/// so its routers can activate as soon as DeployLaunchpads has run.
contract FinishLaunchpads is LaunchpadsBase {
    function run() external {
        Launchpads memory d = _lpLoad();
        require(_has(d.exile), "run DeployLaunchpads first");
        Exile exile = Exile(payable(d.exile));

        vm.startBroadcast(_deployerKey());
        for (uint256 i; i < PADS; ++i) {
            if (!_needsRegistrar(i)) continue;
            address f = d.pads[i].factory;
            require(_has(f), string.concat("no ", _padName(i), " factory recorded; run DeployLaunchpads"));
            if (exile.isRegistrar(f)) continue;
            uint64 eta = exile.registrarEta(f);
            require(eta != 0, string.concat(_padName(i), " factory was never proposed (or the proposal was dropped)"));
            require(block.timestamp >= eta, string.concat(_padName(i), " factory: the 12 hours haven't passed"));
            require(
                block.timestamp <= eta + exile.EXECUTION_WINDOW(),
                string.concat(_padName(i), " factory: the proposal expired; run DeployLaunchpads again")
            );
            exile.addRegistrar(f);
        }
        vm.stopBroadcast();

        for (uint256 i; i < PADS; ++i) {
            if (!_needsRegistrar(i)) continue;
            require(exile.isRegistrar(d.pads[i].factory), "registrar not added");
            console2.log(_padName(i), "factory is an Exile registrar", d.pads[i].factory);
        }
        if (exile.owner() != d.owner) {
            console2.log("Exile's owner is still", exile.owner());
            console2.log("the multisig must call Exile.acceptOwner()", d.owner);
        }
    }
}
