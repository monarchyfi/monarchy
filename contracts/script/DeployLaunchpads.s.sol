// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchpadsBase} from "./LaunchpadsBase.s.sol";
import {console2} from "forge-std/Script.sol";
import {Exile} from "../src/Exile.sol";
import {Sandfall} from "../src/Sandfall.sol";
import {Lodestar} from "../src/Lodestar.sol";
import {LodestarFactory} from "../src/LodestarFactory.sol";
import {V4PriceObserver} from "../src/V4PriceObserver.sol";
import {V4Swapper} from "../src/V4Swapper.sol";
import {AscendV5Swapper} from "../src/AscendV5Swapper.sol";
import {AscendV5Launcher} from "../src/AscendV5Launcher.sol";
import {IV4PoolManager} from "../src/interfaces/IUniswapV4.sol";
import {IExile} from "../src/interfaces/IExile.sol";
import {ISandfall} from "../src/interfaces/ISandfall.sol";
import {IFeeSource} from "../src/interfaces/IFeeSource.sol";
import {VoltaFeeSource} from "../src/sources/VoltaFeeSource.sol";
import {KleosFeeSource} from "../src/sources/KleosFeeSource.sol";
import {BoxaFeeSource} from "../src/sources/BoxaFeeSource.sol";
import {AscendV5FeeSource} from "../src/sources/AscendV5FeeSource.sol";
import {ElysPumpFeeSource} from "../src/sources/ElysPumpFeeSource.sol";
import {MontraFeeSource} from "../src/sources/MontraFeeSource.sol";
import {IAscendV5Launchpad} from "../src/interfaces/IAscendV5.sol";

/// @notice Step 1 of 2 for Monarchy on Ascend v5, Volta, ElysPump, Boxa, Kleos and Montra (Elysium mainnet). Deploys what
/// deployments/launchpads/<chainId>.json doesn't already record, so a run that stopped halfway can be repeated:
/// - the shared core: Exile, Sandfall, the Lodestar implementation (reused from deployments/<chainId>.json when the
///   Ascend core is already on this chain, so every Monarchy router shares one Exile) and the V4PriceObserver;
/// - per launchpad: its adapter with the known hooks, a buyback swapper per pool manager (a V4Swapper; on Ascend v5 an
///   AscendV5Swapper), and a LodestarFactory with no default swapper (phase 1: the buyback share waits in each
///   router's reserve until a swapper is set, unless the creator picks Monarchy's swapper at activation); on Ascend v5
///   also an AscendV5Launcher, which launches new coins with their router as fee owner from the first trade. The
///   factory only takes its launches once the owner calls `setLauncher` (printed when the deployer isn't the owner).
/// FACTORY_OWNER (required) owns every factory and adapter and is handed Exile; on mainnet it must be a multisig.
/// Each factory names its routers' harvests in Exile, so it has to become an Exile registrar, which takes 12 hours:
/// this script proposes the ElysPump, Boxa and Kleos factories, and FinishLaunchpads adds them once the timelock has
/// passed (anyone may run it). Ascend v5, Volta and Montra routers never name a harvest, so their factories never
/// need the role and their routers can activate straight away.
/// Exile goes to FACTORY_OWNER in the same run, so the multisig must then call `Exile.acceptOwner()`.
/// No ElysPump, Boxa or Kleos router can activate before FinishLaunchpads. On a fork from before Ascend v5 went live
/// (block 422319) the Ascend pad is skipped.
contract DeployLaunchpads is LaunchpadsBase {
    function run() external {
        bool rehearsal = block.chainid == 31337;
        require(block.chainid == ELYSIUM_MAINNET || rehearsal, "the launchpads are on Elysium mainnet (99901)");
        uint256 pk = _deployerKey();
        address me = vm.addr(pk);
        Launchpads memory d = _lpLoad();

        // no default to the deployer here: the owner names upgrade successors, adds hook generations and rescues
        // stranded routers, so it must be chosen on purpose
        address owner = vm.envAddress("FACTORY_OWNER");
        require(owner != address(0), "FACTORY_OWNER is the zero address");
        require(
            owner.code.length > 0 || rehearsal || vm.envOr("ALLOW_EOA_OWNER", false),
            "FACTORY_OWNER must be a multisig on this chain (ALLOW_EOA_OWNER=true to override)"
        );
        require(d.owner == address(0) || d.owner == owner, "the file records another owner; its factories keep it");
        d.owner = owner;

        // share the Ascend core when it is already here
        Deployment memory ascend = _load();
        if (!_has(d.exile) && _has(ascend.exile)) d.exile = ascend.exile;
        if (!_has(d.sandfall) && _has(ascend.sandfall)) d.sandfall = ascend.sandfall;
        if (!_has(d.lodestarImpl) && _has(ascend.lodestarImpl)) d.lodestarImpl = ascend.lodestarImpl;

        vm.startBroadcast(pk);
        if (!_has(d.exile)) {
            d.exile = address(new Exile());
            d.startBlock = block.number;
        }
        if (!_has(d.sandfall)) d.sandfall = address(new Sandfall());
        if (!_has(d.lodestarImpl)) d.lodestarImpl = address(new Lodestar());
        if (!_has(d.observer)) d.observer = address(new V4PriceObserver());
        if (d.startBlock == 0) d.startBlock = block.number;

        for (uint256 i; i < PADS; ++i) {
            d.pads[i] = _deployPad(d, i, owner);
        }
        if (_has(d.pads[ASCEND].factory)) _nameLauncher(d.pads[ASCEND], me);

        Exile exile = Exile(payable(d.exile));
        bool exileMine = exile.owner() == me;
        for (uint256 i; i < PADS; ++i) {
            address f = d.pads[i].factory;
            if (!_needsRegistrar(i) || !_has(f) || exile.isRegistrar(f)) continue;
            uint64 eta = exile.registrarEta(f);
            // a proposal still inside its window would only restart its 12 hours
            if (eta != 0 && block.timestamp <= eta + exile.EXECUTION_WINDOW()) continue;
            if (exileMine) {
                exile.proposeRegistrar(f);
            } else {
                console2.log("Exile's owner must propose this factory as a registrar:", f);
                console2.logBytes(abi.encodeCall(Exile.proposeRegistrar, (f)));
            }
        }
        if (exileMine && owner != me && exile.pendingOwner() != owner) exile.transferOwner(owner);
        vm.stopBroadcast();

        _lpSave(d);
        console2.log("Exile", d.exile);
        console2.log("Sandfall", d.sandfall);
        console2.log("Lodestar implementation", d.lodestarImpl);
        console2.log("V4PriceObserver", d.observer);
        for (uint256 i; i < PADS; ++i) {
            if (!_has(d.pads[i].factory)) {
                console2.log(_padName(i), "skipped: the launchpad isn't on this chain (or this fork's block)");
                continue;
            }
            console2.log(_padName(i), "factory", d.pads[i].factory);
            console2.log(_padName(i), "adapter", d.pads[i].source);
            if (_has(d.pads[i].launcher)) console2.log(_padName(i), "launcher", d.pads[i].launcher);
        }
        console2.log("owner", owner);
        if (exile.pendingOwner() == owner) console2.log("next: the owner calls Exile.acceptOwner()");
        console2.log("next: FinishLaunchpads after", uint256(exile.TIMELOCK()), "seconds");
    }

    function _deployPad(Launchpads memory d, uint256 i, address owner) internal returns (Pad memory p) {
        p = d.pads[i];
        // a rehearsal fork from before Ascend v5 went live has no launchpad to adapt
        if (i == ASCEND && ASCEND_V5_LAUNCHPAD.code.length == 0) return p;
        (address[] memory hooks, uint8[] memory kinds, address[] memory pms) = _registry(i);
        V4PriceObserver observer = V4PriceObserver(d.observer);
        if (!_has(p.source)) {
            if (i == VOLTA) {
                p.source = address(new VoltaFeeSource(observer, owner, hooks, kinds));
            } else if (i == ELYSPUMP) {
                p.source = address(new ElysPumpFeeSource(observer, owner, hooks, kinds));
            } else if (i == BOXA) {
                p.source = address(new BoxaFeeSource(observer, owner, hooks, kinds));
            } else if (i == KLEOS) {
                p.source = address(new KleosFeeSource(observer, owner, hooks, kinds));
            } else if (i == MONTRA) {
                p.source = address(new MontraFeeSource(observer, owner, hooks, kinds));
            } else {
                // stateless and ownerless: it reads the pool manager and escrow factory from the launchpad, and the
                // price from Ascend's own EMA, so it needs neither the observer nor the owner
                p.source = address(
                    new AscendV5FeeSource(IAscendV5Launchpad(ASCEND_V5_LAUNCHPAD), ASCEND_V5_BURN_SINK)
                );
            }
        }
        address[] memory swappers = new address[](pms.length);
        for (uint256 j; j < pms.length; ++j) {
            require(pms[j].code.length > 0, "no pool manager at the recorded address");
            swappers[j] = _swapperFor(p, pms[j]);
            if (_has(swappers[j])) continue;
            if (i == ASCEND) {
                AscendV5Swapper s = new AscendV5Swapper(IAscendV5Launchpad(ASCEND_V5_LAUNCHPAD));
                require(address(s.poolManager()) == pms[j], "Ascend's launchpad uses another pool manager");
                swappers[j] = address(s);
            } else {
                swappers[j] = address(new V4Swapper(IV4PoolManager(pms[j]), observer));
            }
        }
        p.poolManagers = pms;
        p.swappers = swappers;
        if (!_has(p.factory)) {
            p.factory = address(
                new LodestarFactory(
                    d.lodestarImpl,
                    IFeeSource(p.source),
                    IExile(d.exile),
                    ISandfall(d.sandfall),
                    address(0), // phase 1: no default swapper
                    owner
                )
            );
        }
        require(address(LodestarFactory(p.factory).source()) == p.source, "factory and adapter don't match");
        if (i == ASCEND && !_has(p.launcher)) {
            p.launcher = address(new AscendV5Launcher(LodestarFactory(p.factory), ASCEND_V5_WHYPE));
        }
    }

    /// @dev The Ascend factory only takes launches from the launcher its owner names: done here when the deployer owns
    /// it (a rehearsal), otherwise printed for the multisig.
    function _nameLauncher(Pad memory p, address me) internal {
        if (!_has(p.launcher) || LodestarFactory(p.factory).launcher() == p.launcher) return;
        if (LodestarFactory(p.factory).owner() == me) {
            LodestarFactory(p.factory).setLauncher(p.launcher);
        } else {
            console2.log("the owner must name the Ascend launcher on factory", p.factory);
            console2.logBytes(abi.encodeCall(LodestarFactory.setLauncher, (p.launcher)));
        }
    }
}
